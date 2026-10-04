// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog

/// Raising a body's place in the backfill queue is the one thing the message view asks for,
/// and `MirrorCoordinator.prioritise(messageId:)` already has that signature. The conformance
/// is here rather than in `NCMailSync` because `BodyPrioritising` is an app-target protocol
/// and dependencies point downward only
/// ([overview.md](../../docs/architecture/overview.md#modules)).
extension MirrorCoordinator: BodyPrioritising {}

/// The path monitor's answer in the shape the sync engine takes it. Here rather than beside
/// ``NetworkConditions`` so that `import NCMailSync` stays in the engine's files.
extension NetworkConditions {
    var mirrorConditions: MirrorConditions {
        MirrorConditions(isOffline: isOffline, isExpensive: isExpensive, isConstrained: isConstrained)
    }
}

/// Every signed-in login's sync machinery, started here and nowhere else.
///
/// Two levels ([ADR-0084](../../docs/decisions/0084-the-shell-starts-logins-before-accounts.md)):
///
/// - **Per login** (one ``AccountSession``): `CalendarListSync`, `ContactsSync`,
///   `ServerResultFetcher` and `ServerStateMirror`, plus the `ContactWriteHandler` every
///   queue and drainer of the login carries. Started when the session is, once its `login`
///   row exists.
/// - **Per account row**: `MirrorCoordinator`, `SyncScheduler` (with its `OperationDrainer`),
///   `AvatarFetcher` and `OutboxSender`. Started from `store.observeAccounts()`, and only
///   once the row's login is running, because the scheduler and the outbox call into the
///   login's server-state mirror and the drainer sends through its contact handler.
///
/// Signing out stops the accounts first, then the login, in reverse start order; nothing for
/// that session is left running. `SettingsCommands` is never running at all: it is built on
/// demand by ``settingsCommands(sessionId:)`` (ADR-0053's pattern).
///
/// This is the only place an engine is *started*, which is deliberate: one started from a
/// view is how "the network never renders"
/// ([overview.md](../../docs/architecture/overview.md#the-invariant)) gets broken. Nothing
/// here returns a decoded payload to a caller either; the engine writes counts into
/// ``AppStatus`` and every other value on screen comes from a row.
///
/// The rows drive the account level rather than the Keychain doing it directly
/// ([ADR-0047](../../docs/decisions/0047-the-account-row-starts-the-engine.md)), so a launch
/// with no network still starts everything it can from what is already mirrored.
@MainActor
final class AccountEngine {
    /// One login, running. A class because its tasks are appended after it is stored.
    private final class RunningLogin {
        let session: AccountSession
        let loginId: Int64
        let engines: LoginEngines
        /// The parts' start tasks, which a stop waits for.
        var starts: [Task<Void, Never>] = []
        var tasks: [Task<Void, Never>] = []

        init(session: AccountSession, loginId: Int64, engines: LoginEngines) {
            self.session = session
            self.loginId = loginId
            self.engines = engines
        }
    }

    /// One account row, running.
    private final class RunningAccount {
        let session: AccountSession
        let engines: AccountEngines
        var starts: [Task<Void, Never>] = []
        var tasks: [Task<Void, Never>] = []

        init(session: AccountSession, engines: AccountEngines) {
            self.session = session
            self.engines = engines
        }
    }

    /// The account whose app password the server refused. `AppSession` turns this into the
    /// one modal the app has.
    var sessionExpired: (@MainActor (AccountSession) -> Void)?

    private let store: MailStore
    private let status: AppStatus
    private let factory: EngineFactory

    /// Keychain identities, by ``AccountSession/id``. An account row is matched back to one
    /// of these by the `(serverURL, loginName)` pair it carries (ADR-0033).
    private var sessions: [String: AccountSession] = [:]
    /// A login whose `login` row is being resolved, by session id. The token is what a
    /// sign-out between the request and the answer invalidates.
    private var loginsStarting: [String: UUID] = [:]
    private var logins: [String: RunningLogin] = [:]
    private var running: [Int64: RunningAccount] = [:]
    /// The latest account rows, kept so a login that finishes starting can start the rows
    /// that were waiting for it.
    private var rows: [AccountRecord] = []
    private var progress: [Int64: MirrorProgress] = [:]
    private var failures: [Int64: Int] = [:]
    private var conditions = NetworkConditions()
    private var selectedMailboxId: Int64?
    private var rowObservation: Task<Void, Never>?

    nonisolated static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "engine")

    init(store: MailStore, status: AppStatus, factory: EngineFactory = .live) {
        self.store = store
        self.status = status
        self.factory = factory
    }

    // MARK: - Lifecycle

    /// Starts every login, observes account rows, and asks each server what accounts it has.
    ///
    /// Safe to call more than once; the observation is started once.
    func start(accounts: [AccountSession]) {
        for account in accounts { add(account) }
    }

    /// A newly signed-in account, or one that has just answered the 401 modal. A session
    /// already running under the same identity is replaced: its engines hold the old
    /// password.
    func add(_ account: AccountSession) {
        if sessions[account.id] != nil || logins[account.id] != nil || loginsStarting[account.id] != nil {
            teardown(sessionId: account.id)
        }
        sessions[account.id] = account
        observeAccountRows()
        startLogin(account)
        discover(account)
    }

    /// Signing out: every engine of this login stops, and none restarts this launch, whatever
    /// rows are still mirrored.
    ///
    /// - Returns: the teardown, for a caller that has to wait before deleting rows the
    ///   engines write to.
    @discardableResult
    func signOut(sessionId: String) -> Task<Void, Never> {
        sessions[sessionId] = nil
        return teardown(sessionId: sessionId)
    }

    /// Stops every engine and the row observation with it.
    ///
    /// Nothing in the running app calls this — the engine lives as long as the process — but
    /// the tests need a way to stop everything.
    @discardableResult
    func stopAll() -> Task<Void, Never> {
        rowObservation?.cancel()
        rowObservation = nil
        let ids = Set(sessions.keys).union(logins.keys).union(loginsStarting.keys)
        sessions.removeAll()
        let teardowns = ids.map { teardown(sessionId: $0) }
        return Task {
            for teardown in teardowns { await teardown.value }
        }
    }

    /// The one path monitor's answer, pushed to every engine rather than each of them polling
    /// for it ([ADR-0031](../../docs/decisions/0031-conditions-pushed-power-read.md)).
    func apply(conditions newConditions: NetworkConditions) {
        guard newConditions != conditions else { return }
        conditions = newConditions
        let mirrorConditions = newConditions.mirrorConditions
        for login in logins.values {
            let parts = login.engines.parts
            login.tasks.append(Task { for part in parts { await part.engineApply(mirrorConditions) } })
        }
        for entry in running.values {
            let parts = entry.engines.parts
            entry.tasks.append(Task { for part in parts { await part.engineApply(mirrorConditions) } })
        }
    }

    /// The Mac woke: contacts and the calendar list sync now rather than at the end of their
    /// ten-minute sleep. Mail needs no nudge; its scheduler's due-check runs on its own.
    func systemDidWake() {
        for login in logins.values {
            let parts = login.engines.parts
            login.tasks.append(Task { for part in parts { await part.engineWake() } })
        }
    }

    /// Settings opened: every login re-reads its server state
    /// (`sync-engine.md` § server state, the `.settingsOpened` trigger).
    func settingsOpened() {
        for login in logins.values {
            guard let serverState = login.engines.serverState else { continue }
            login.tasks.append(Task { await serverState.refresh(trigger: .settingsOpened) })
        }
    }

    /// The mailbox the user is reading. It lengthens that mailbox's sync interval and keeps a
    /// reconcile off the list being scrolled.
    ///
    /// Every scheduler is told, not just the selected mailbox's own account: a mailbox id is
    /// unique mirror-wide (ADR-0033), so an account that does not own it correctly concludes
    /// that none of its mailboxes is selected.
    func setSelectedMailbox(_ mailboxId: Int64?) {
        guard mailboxId != selectedMailboxId else { return }
        selectedMailboxId = mailboxId
        for entry in running.values {
            let select = entry.engines.setSelectedMailbox
            entry.tasks.append(Task { await select(mailboxId) })
        }
    }

    /// `R`, the toolbar's Refresh and the sidebar's. Every scheduler is asked, or only
    /// `accountId`'s; one that does not own `mailboxId` resolves no targets and does nothing,
    /// which is cheaper than resolving the owning account here with a database read.
    ///
    /// ``AppStatus/refreshesInFlight`` counts until every pass returns, which is what the
    /// Refresh button's spinner shows.
    func refresh(mailboxId: Int64?, accountId: Int64? = nil) {
        let passes = running.filter { accountId == nil || $0.key == accountId }.map(\.value.engines.syncNow)
        guard !passes.isEmpty else { return }
        status.refreshesInFlight += 1
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for pass in passes {
                    group.addTask { await pass(mailboxId) }
                }
            }
            self?.status.refreshesInFlight -= 1
        }
    }

    /// The footer's Retry: every account's drainer clears its backoff and takes everything
    /// at once.
    func retryFailedActions() {
        for entry in running.values {
            let retry = entry.engines.retryFailed
            entry.tasks.append(Task { await retry() })
        }
    }

    /// A triage action just queued something for this account (WS-10). The queue writes the
    /// row and the drain is what sends it; this is only the nudge.
    func wakeDrainer(accountId: Int64) {
        guard let entry = running[accountId] else { return }
        let wake = entry.engines.wakeDrainer
        entry.tasks.append(Task { await wake() })
    }

    // MARK: - What the columns need

    /// The signed-in account a mirror row belongs to, and the coordinator that can raise one
    /// of its bodies up the queue. Nil until that row's coordinator is running.
    func account(id: Int64) -> (session: AccountSession, prioritiser: any BodyPrioritising)? {
        guard let entry = running[id], let prioritiser = entry.engines.prioritiser else { return nil }
        return (entry.session, prioritiser)
    }

    /// The composer's and the outbox view's engine for one account (WS-27).
    func outbox(accountId: Int64) -> OutboxSender? {
        running[accountId]?.engines.outbox
    }

    /// ADR-0067's on-demand results for one login: summaries, smart replies, translations.
    func serverResults(sessionId: String) -> ServerResultFetcher? {
        logins[sessionId]?.engines.results
    }

    /// The login's server-state mirror, for Priority inbox's follow-up check.
    func serverState(sessionId: String) -> ServerStateMirror? {
        logins[sessionId]?.engines.serverState
    }

    /// A queue for one account that can take every kind, the contact and calendar ones
    /// included, and wakes that account's drainer after each commit.
    func mutationQueue(accountId: Int64) -> MutationQueue {
        let entry = running[accountId]
        let configuration = entry.flatMap { logins[$0.session.id] }?.engines.queueConfiguration
        return MutationQueue(
            store: store,
            drainer: entry?.engines.drainer,
            configuration: configuration ?? MutationQueueConfiguration()
        )
    }

    /// The queue for a login's contact and calendar writes. They are queued under the login's
    /// lowest-id mail account, which is the drainer that sends them (WS-24).
    func contactsQueue(sessionId: String) -> MutationQueue? {
        let ids = running.filter { $0.value.session.id == sessionId }.keys
        guard let accountId = ids.min() else { return nil }
        return mutationQueue(accountId: accountId)
    }

    /// Settings' validated commands for one login, built fresh for each use and not kept:
    /// it has no loop and no state worth sharing
    /// ([ADR-0053](../../docs/decisions/0053-settings-builds-its-own-short-lived-coordinators.md),
    /// [ADR-0068](../../docs/decisions/0068-settings-commands.md)).
    func settingsCommands(sessionId: String) -> SettingsCommands? {
        guard let session = sessions[sessionId] else { return nil }
        return SettingsCommands(store: store, client: session.client, identity: session.identity)
    }

    // MARK: - Start mailbox

    /// Saves a selection the user stayed on as the server's `start-mailbox-id`, through the
    /// queue so it survives being offline. A mailbox goes to its own login; Unified and
    /// Priority inbox go to every signed-in login. A login already holding the value is left
    /// alone, as the web client does.
    func saveStartMailbox(_ selection: SidebarSelection) async {
        var targets: [(identity: ServerIdentity, accountId: Int64, value: String)] = []
        do {
            if let mailboxId = selection.mailboxId {
                guard
                    let mailbox = try await store.mailbox(id: mailboxId),
                    let account = try await store.account(id: mailbox.accountId),
                    let value = StartMailbox.value(for: selection, remoteMailboxId: mailbox.remoteId)
                else { return }
                targets.append(
                    (ServerIdentity(serverURL: account.serverURL, loginName: account.loginName), account.id, value))
            } else if let value = StartMailbox.value(for: selection, remoteMailboxId: nil) {
                for session in sessions.values {
                    guard let account = try await store.accounts(identity: session.identity).min(by: { $0.id < $1.id })
                    else { continue }
                    targets.append((session.identity, account.id, value))
                }
            }
            for target in targets {
                guard let loginId = try await store.login(for: target.identity)?.id else { continue }
                let current = try await store.preferenceValue(key: StartMailbox.preferenceKey, loginId: loginId)
                guard current != target.value else { continue }
                try await mutationQueue(accountId: target.accountId).perform(
                    .setPreference(key: StartMailbox.preferenceKey, value: target.value),
                    accountId: target.accountId
                )
            }
        } catch {
            Self.logger.error("could not save the start mailbox: \(String(describing: error), privacy: .public)")
        }
    }

    /// Where a launch with no saved selection opens: the first signed-in login, in a stable
    /// order, whose `start-mailbox-id` names something that still exists.
    func startMailbox() async -> SidebarSelection? {
        for session in sessions.values.sorted(by: { $0.id < $1.id }) {
            do {
                guard
                    let loginId = try await store.login(for: session.identity)?.id,
                    let value = try await store.preferenceValue(key: StartMailbox.preferenceKey, loginId: loginId)
                else { continue }
                var byRemoteId: [Int64: Int64] = [:]
                for account in try await store.accounts(identity: session.identity) {
                    for mailbox in try await store.mailboxes(accountId: account.id) {
                        byRemoteId[mailbox.remoteId] = mailbox.id
                    }
                }
                if let selection = StartMailbox.selection(for: value, localMailboxId: { byRemoteId[$0] }) {
                    return selection
                }
            } catch {
                Self.logger.error("could not read the start mailbox: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Logins

    /// Resolves the session's `login` row, then builds and starts its engines, then any
    /// account rows that were waiting for them.
    private func startLogin(_ session: AccountSession) {
        guard logins[session.id] == nil, loginsStarting[session.id] == nil else { return }
        let token = UUID()
        loginsStarting[session.id] = token
        Task { [weak self, store] in
            let loginId: Int64?
            do {
                loginId = try await store.ensureLogin(session.identity).id
            } catch {
                Self.logger.error("could not resolve a login row: \(String(describing: error), privacy: .public)")
                loginId = nil
            }
            guard let self, loginsStarting[session.id] == token else { return }
            loginsStarting[session.id] = nil
            guard let loginId else { return }
            run(login: session, loginId: loginId)
        }
    }

    private func run(login session: AccountSession, loginId: Int64) {
        let engines = factory.login(store, session, loginId) { [weak self] messageIds in
            await self?.clearFollowUps(messageIds)
        }
        let entry = RunningLogin(session: session, loginId: loginId, engines: engines)
        logins[session.id] = entry
        entry.starts = start(engines.parts)
        Self.logger.info("login \(loginId, privacy: .public) running")
        apply(rows: rows)
    }

    /// `ServerStateMirror.checkFollowUps` found these answered: their `$follow_up` tag comes
    /// off through the queue, one operation per account (WS-22's `unsetTag`).
    private func clearFollowUps(_ messageIds: [Int64]) async {
        var byAccount: [Int64: [Int64]] = [:]
        for id in messageIds {
            guard let message = try? await store.message(id: id) else { continue }
            byAccount[message.accountId, default: []].append(id)
        }
        for (accountId, ids) in byAccount {
            do {
                try await mutationQueue(accountId: accountId).perform(
                    .unsetTag(messageIds: ids, imapLabel: "$follow_up"),
                    accountId: accountId
                )
            } catch {
                Self.logger.error("could not clear follow-ups: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Rows

    private func observeAccountRows() {
        guard rowObservation == nil else { return }
        rowObservation = Task { [weak self, store] in
            do {
                for try await rows in store.observeAccounts() {
                    guard let self else { return }
                    apply(rows: rows)
                }
            } catch {
                Self.logger.error("account observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func apply(rows newRows: [AccountRecord]) {
        rows = newRows
        let ids = Set(newRows.map(\.id))
        for (id, entry) in running where !ids.contains(id) {
            running[id] = nil
            progress[id] = nil
            failures[id] = nil
            _ = Self.stop(entry.engines.parts, starts: entry.starts, cancelling: entry.tasks)
        }
        for row in newRows where running[row.id] == nil {
            let key = AccountSession.identifier(server: row.serverURL, loginName: row.loginName)
            guard let session = sessions[key] else {
                // A row from a sign-in this launch has not seen, or one signed out. Nothing
                // can talk to it until its Keychain entry is read at the next launch.
                Self.logger.info("account \(row.id, privacy: .public) has no credentials this launch")
                continue
            }
            // Started by `run(login:loginId:)` once the login is.
            guard let login = logins[key] else { continue }
            startRunning(row: row, session: session, login: login.engines)
        }
        refreshStatus()
    }

    private func startRunning(row: AccountRecord, session: AccountSession, login: LoginEngines) {
        let engines = factory.account(store, row, session, login)
        let entry = RunningAccount(session: session, engines: engines)
        running[row.id] = entry

        let selected = selectedMailboxId
        let select = engines.setSelectedMailbox
        entry.tasks.append(Task { await select(selected) })
        entry.starts = start(engines.parts)
        if let stream = engines.progress {
            entry.tasks.append(
                Task { [weak self] in
                    for await value in stream {
                        guard let self else { return }
                        progress[row.id] = value
                        refreshStatus()
                    }
                }
            )
        }
        if let stream = engines.pendingSummary {
            entry.tasks.append(
                Task { [weak self] in
                    // The first element is the summary as it stands, so a footer drawn late
                    // is not blank until the next queued action.
                    for await summary in stream {
                        guard let self else { return }
                        failures[row.id] = summary.failing
                        refreshStatus()
                    }
                }
            )
        }
        Self.logger.info("account \(row.id, privacy: .public) running")
    }

    // MARK: - Starting and stopping

    /// Each part is told the current conditions before it starts, on its own task, so one
    /// slow start (the outbox's resume, which may send) delays nothing else. A start that was
    /// cancelled before it got there does not start at all.
    private func start(_ parts: [any EnginePart]) -> [Task<Void, Never>] {
        let mirrorConditions = conditions.mirrorConditions
        return parts.map { part in
            Task {
                await part.engineApply(mirrorConditions)
                guard !Task.isCancelled else { return }
                await part.engineStart()
            }
        }
    }

    /// Cancels what the engine itself started, waits for any start still in flight — so a
    /// part is never started after it was stopped — then stops the parts in reverse start
    /// order.
    private nonisolated static func stop(
        _ parts: [any EnginePart],
        starts: [Task<Void, Never>],
        cancelling tasks: [Task<Void, Never>]
    ) -> Task<Void, Never> {
        for task in starts + tasks { task.cancel() }
        return Task {
            for start in starts { await start.value }
            for part in parts.reversed() { await part.engineStop() }
        }
    }

    /// Accounts first, then the login they depend on.
    @discardableResult
    private func teardown(sessionId: String) -> Task<Void, Never> {
        loginsStarting[sessionId] = nil
        var accountStops: [Task<Void, Never>] = []
        for (id, entry) in running where entry.session.id == sessionId {
            running[id] = nil
            progress[id] = nil
            failures[id] = nil
            accountStops.append(Self.stop(entry.engines.parts, starts: entry.starts, cancelling: entry.tasks))
        }
        let login = logins.removeValue(forKey: sessionId)
        refreshStatus()
        let loginParts = login?.engines.parts ?? []
        let loginStarts = login?.starts ?? []
        let loginTasks = login?.tasks ?? []
        let loginId = login?.loginId
        return Task {
            for stop in accountStops { await stop.value }
            await Self.stop(loginParts, starts: loginStarts, cancelling: loginTasks).value
            if let loginId { Self.logger.info("login \(loginId, privacy: .public) stopped") }
        }
    }

    /// Asks a signed-in server for its accounts, which is what writes the rows the
    /// observation above is waiting for.
    ///
    /// One task per login, so a server that is down or a password that was revoked delays
    /// nothing but itself.
    private func discover(_ account: AccountSession) {
        let discover = factory.discover
        Task { [weak self, store] in
            do {
                try await discover(store, account)
            } catch MailError.unauthorized {
                self?.sessionExpired?(account)
            } catch {
                Self.logger.error("account discovery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Status

    private func refreshStatus() {
        status.mirror = AccountEngine.combined(progress: Array(progress.values))
        status.pendingFailures = failures.values.reduce(0, +)
    }

    /// One footer line for any number of accounts: the counts are added up.
    ///
    /// The alternative was to show the account that is furthest behind, which needs a name
    /// beside the number to mean anything and turns one line into two
    /// ([ADR-0048](../../docs/decisions/0048-one-footer-for-every-account.md)). A sum is
    /// complete only when every part is, so the footer clears when the last account finishes
    /// and not when the first does.
    nonisolated static func combined(progress: [MirrorProgress]) -> MirrorProgress? {
        guard !progress.isEmpty else { return nil }
        return progress.reduce(
            into: MirrorProgress(totalMessages: 0, bodiesPresent: 0, bodiesFailed: 0, mailboxesRemaining: 0)
        ) {
            sum,
            value in
            sum.totalMessages += value.totalMessages
            sum.bodiesPresent += value.bodiesPresent
            sum.bodiesFailed += value.bodiesFailed
            sum.mailboxesRemaining += value.mailboxesRemaining
        }
    }
}
