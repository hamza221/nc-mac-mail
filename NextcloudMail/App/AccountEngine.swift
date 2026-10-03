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
/// ``NetworkConditions`` so that `import NCMailSync` stays in this one file.
extension NetworkConditions {
    var mirrorConditions: MirrorConditions {
        MirrorConditions(isOffline: isOffline, isExpensive: isExpensive, isConstrained: isConstrained)
    }
}

/// Every account's sync machinery: one `MirrorCoordinator`, one `OperationDrainer`, one
/// `SyncScheduler` and one `AvatarFetcher` per account row, started here and nowhere else.
///
/// This is the only place a coordinator, a drainer or a scheduler is *started*, which is
/// deliberate: one started from a view is how "the network never renders"
/// ([overview.md](../../docs/architecture/overview.md#the-invariant)) gets broken. (WS-10's
/// `MessageActions` imports `NCMailSync` too, for `MailOperation` and `MutationQueue`, and
/// starts nothing.) Nothing here returns a decoded payload to a caller either. The engine
/// reads `store.observeAccounts()` and writes counts into ``AppStatus``; every other value on
/// screen comes from a row.
///
/// The rows drive the engine rather than the Keychain doing it directly.
/// `MirrorCoordinator.discoverAccounts` writes the rows and the observation starts a
/// coordinator for each one, so a launch with no network still starts everything it can from
/// what is already mirrored, and a server that answers late is picked up when it does
/// ([ADR-0047](../../docs/decisions/0047-the-account-row-starts-the-engine.md)).
@MainActor
final class AccountEngine {
    /// One account row, running. A class rather than a struct because its tasks are appended
    /// after the coordinators it holds are already in the dictionary.
    private final class Running {
        let account: AccountSession
        let mirror: MirrorCoordinator
        let drainer: OperationDrainer
        let scheduler: SyncScheduler
        let avatars: AvatarFetcher
        var tasks: [Task<Void, Never>] = []

        init(
            account: AccountSession,
            mirror: MirrorCoordinator,
            drainer: OperationDrainer,
            scheduler: SyncScheduler,
            avatars: AvatarFetcher
        ) {
            self.account = account
            self.mirror = mirror
            self.drainer = drainer
            self.scheduler = scheduler
            self.avatars = avatars
        }
    }

    /// The account whose app password the server refused. `AppSession` turns this into the
    /// one modal the app has.
    var sessionExpired: (@MainActor (AccountSession) -> Void)?

    private let store: MailStore
    private let status: AppStatus

    /// Keychain identities, by ``AccountSession/id``. An account row is matched back to one
    /// of these by the `(serverURL, loginName)` pair it carries (ADR-0033).
    private var sessions: [String: AccountSession] = [:]
    private var running: [Int64: Running] = [:]
    private var progress: [Int64: MirrorProgress] = [:]
    private var failures: [Int64: Int] = [:]
    private var conditions = NetworkConditions()
    private var selectedMailboxId: Int64?
    private var rowObservation: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "engine")

    init(store: MailStore, status: AppStatus) {
        self.store = store
        self.status = status
    }

    // MARK: - Lifecycle

    /// Starts observing account rows, and asks each signed-in server what accounts it has.
    ///
    /// Safe to call more than once; the observation is started once.
    func start(accounts: [AccountSession]) {
        for account in accounts { sessions[account.id] = account }
        observeAccountRows()
        for account in accounts { discover(account) }
    }

    /// Stops every account's machinery and the row observation with it.
    ///
    /// Nothing in the running app calls this — the engine lives as long as the process — but
    /// signing an account out (WS-12) and the live test below both need a way to stop.
    func stopAll() {
        rowObservation?.cancel()
        rowObservation = nil
        for entry in running.values { stop(entry) }
        running.removeAll()
        progress.removeAll()
        failures.removeAll()
        refreshStatus()
    }

    /// A newly signed-in account, or one that has just answered the 401 modal.
    func add(_ account: AccountSession) {
        sessions[account.id] = account
        observeAccountRows()
        discover(account)
    }

    /// The one path monitor's answer, pushed to every coordinator and scheduler rather than
    /// each of them polling for it ([ADR-0031](../../docs/decisions/0031-conditions-pushed-power-read.md)).
    func apply(conditions newConditions: NetworkConditions) {
        guard newConditions != conditions else { return }
        conditions = newConditions
        let mirrorConditions = newConditions.mirrorConditions
        for entry in running.values {
            let mirror = entry.mirror
            let scheduler = entry.scheduler
            let avatars = entry.avatars
            entry.tasks.append(
                Task {
                    await mirror.apply(conditions: mirrorConditions)
                    await scheduler.apply(conditions: mirrorConditions)
                    await avatars.apply(conditions: mirrorConditions)
                }
            )
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
            let scheduler = entry.scheduler
            entry.tasks.append(Task { await scheduler.setSelectedMailbox(mailboxId) })
        }
    }

    /// `R`, the toolbar's Refresh and the sidebar's. Every scheduler is asked, or only
    /// `accountId`'s; one that does not own `mailboxId` resolves no targets and does nothing,
    /// which is cheaper than resolving the owning account here with a database read.
    ///
    /// ``AppStatus/refreshesInFlight`` counts until every pass returns, which is what the
    /// Refresh button's spinner shows. That tracks the sync passes themselves, not a request
    /// the view is waiting on, so the button can't claim more than the schedulers did.
    func refresh(mailboxId: Int64?, accountId: Int64? = nil) {
        let schedulers = running.filter { accountId == nil || $0.key == accountId }.map(\.value.scheduler)
        guard !schedulers.isEmpty else { return }
        status.refreshesInFlight += 1
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for scheduler in schedulers {
                    group.addTask { await scheduler.syncNow(mailboxId: mailboxId) }
                }
            }
            self?.status.refreshesInFlight -= 1
        }
    }

    /// The footer's Retry: every account's drainer clears its backoff and takes everything
    /// at once. Failing rows keep their attempt counts, so the indicator only clears if the
    /// server now accepts them.
    func retryFailedActions() {
        for entry in running.values {
            let drainer = entry.drainer
            entry.tasks.append(Task { await drainer.retryAll() })
        }
    }

    /// A triage action just queued something for this account (WS-10). The queue writes the
    /// row and the drain is what sends it; this is only the nudge.
    func wakeDrainer(accountId: Int64) {
        guard let entry = running[accountId] else { return }
        let drainer = entry.drainer
        entry.tasks.append(Task { await drainer.wake() })
    }

    // MARK: - What the columns need

    /// The signed-in account an mirror row belongs to, and the coordinator that can raise one
    /// of its bodies up the queue. Nil until that row's coordinator is running.
    func account(id: Int64) -> (session: AccountSession, prioritiser: any BodyPrioritising)? {
        guard let entry = running[id] else { return nil }
        return (entry.account, entry.mirror)
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

    private func apply(rows: [AccountRecord]) {
        let ids = Set(rows.map(\.id))
        for (id, entry) in running where !ids.contains(id) {
            stop(entry)
            running[id] = nil
            progress[id] = nil
            failures[id] = nil
        }
        for row in rows where running[row.id] == nil {
            let key = AccountSession.identifier(server: row.serverURL, loginName: row.loginName)
            guard let account = sessions[key] else {
                // A row from a sign-in this launch has not seen. Nothing can talk to it until
                // its Keychain entry is read, which happens at the next launch.
                Self.logger.info("account \(row.id, privacy: .public) has no credentials this launch")
                continue
            }
            startRunning(row: row, account: account)
        }
        refreshStatus()
    }

    private func startRunning(row: AccountRecord, account: AccountSession) {
        let mirror = MirrorCoordinator(store: store, client: account.client, accountId: row.id)
        let drainer = OperationDrainer(store: store, client: account.client, accountId: row.id)
        let scheduler = SyncScheduler(
            store: store,
            client: account.client,
            accountId: row.id,
            drainer: drainer,
            mirror: mirror
        )
        let avatars = AvatarFetcher(store: store, client: account.client, accountId: row.id)
        let entry = Running(
            account: account,
            mirror: mirror,
            drainer: drainer,
            scheduler: scheduler,
            avatars: avatars
        )
        running[row.id] = entry

        let mirrorConditions = conditions.mirrorConditions
        let selected = selectedMailboxId
        entry.tasks.append(
            Task {
                await mirror.apply(conditions: mirrorConditions)
                await mirror.start()
            }
        )
        entry.tasks.append(
            Task {
                await scheduler.apply(conditions: mirrorConditions)
                await scheduler.setSelectedMailbox(selected)
                await scheduler.start()
            }
        )
        entry.tasks.append(
            Task {
                await avatars.apply(conditions: mirrorConditions)
                await avatars.start()
            }
        )
        entry.tasks.append(
            Task { [weak self] in
                for await value in mirror.progress {
                    guard let self else { return }
                    progress[row.id] = value
                    refreshStatus()
                }
            }
        )
        entry.tasks.append(
            Task { [weak self] in
                // The first element is the summary as it stands, so a footer drawn late is
                // not blank until the next queued action.
                for await summary in drainer.pendingCount {
                    guard let self else { return }
                    failures[row.id] = summary.failing
                    refreshStatus()
                }
            }
        )
        Self.logger.info("account \(row.id, privacy: .public) running")
    }

    private func stop(_ entry: Running) {
        for task in entry.tasks { task.cancel() }
        entry.tasks.removeAll()
        let scheduler = entry.scheduler
        let avatars = entry.avatars
        Task {
            await scheduler.stop()
            await avatars.stop()
        }
    }

    /// Asks each signed-in server for its accounts, which is what writes the rows the
    /// observation above is waiting for.
    ///
    /// One account per task, so a server that is down or a password that was revoked delays
    /// nothing but itself.
    private func discover(_ account: AccountSession) {
        Task { [weak self, store] in
            do {
                let rows = try await MirrorCoordinator.discoverAccounts(
                    store: store,
                    client: account.client,
                    identity: ServerIdentity(serverURL: account.server, loginName: account.loginName)
                )
                Self.logger.info("discovered \(rows.count, privacy: .public) account(s) for one identity")
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
