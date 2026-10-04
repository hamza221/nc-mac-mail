// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore

/// Why a server-state refresh ran. `sync-engine.md` § server state: at launch, at every deep
/// reconcile, and when Settings opens.
public enum ServerStateTrigger: String, Sendable {
    case launch
    case deepReconcile
    case settingsOpened
}

/// One mirrored family of server state, for the refresh report.
public enum ServerStateKind: String, Sendable, CaseIterable, Comparable {
    /// Account settings and signatures, and the aliases embedded in the same payload.
    case accounts
    case quota
    case delegations
    case sieve
    case quickActions
    case preferences
    case textBlocks
    case trustedSenders
    case internalAddresses
    case smimeCertificates
    case outbox

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }
}

/// What one refresh did, for the debug pane, the tests and the live measurement. Counts
/// and error names only — never a payload.
public struct ServerStateRefreshReport: Sendable, Equatable {
    public var trigger: ServerStateTrigger
    /// Kinds whose every request succeeded and whose rows were replaced.
    public var refreshed: Set<ServerStateKind> = []
    /// Kinds with at least one failed request, with the first error's name. Their rows are
    /// as the last successful refresh left them.
    public var failed: [ServerStateKind: String] = [:]
    public var requests = 0
    /// True when the refresh did nothing because the device is offline.
    public var skippedOffline = false
    public var duration: Duration = .zero

    /// Folds in the report of one concurrent item: a kind is refreshed only if no item of
    /// it failed, and keeps the first failure it saw.
    mutating func merge(_ other: ServerStateRefreshReport) {
        for (kind, error) in other.failed where failed[kind] == nil {
            failed[kind] = error
            refreshed.remove(kind)
        }
        for kind in other.refreshed where failed[kind] == nil {
            refreshed.insert(kind)
        }
    }

    public init(trigger: ServerStateTrigger) {
        self.trigger = trigger
    }
}

/// The knobs, injectable so a test owns the clock and the sleeper.
public struct ServerStateConfiguration: Sendable {
    /// How often the outbox is re-read while it holds anything. The brief's 60 s.
    public var outboxPollInterval: Duration
    /// Requests in flight during a refresh (`networking.md` § concurrency budget).
    public var concurrency: Int
    /// The `GET /api/preferences/{key}` keys mirrored — the ones the web client's page
    /// state carries (`PageController::index`, Mail 5.12), minus the instance values that
    /// are not user preferences (ADR-0078 covers those).
    public var preferenceKeys: [String]
    public var now: @Sendable () -> Int64
    public var sleep: @Sendable (Duration) async throws -> Void

    public static let webClientPreferenceKeys = [
        "sort-order", "layout-mode", "layout-message-view", "reply-mode", "external-avatars",
        "collect-data", "search-priority-body", "start-mailbox-id", "follow-up-reminders",
        "sort-favorites", "compact-mode", "auto-mark-as-read", "internal-addresses",
        "smime-sign-aliases", "account-settings", "index-context-chat",
    ]

    public init(
        outboxPollInterval: Duration = .seconds(60),
        concurrency: Int = 4,
        preferenceKeys: [String] = Self.webClientPreferenceKeys,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.outboxPollInterval = outboxPollInterval
        self.concurrency = concurrency
        self.preferenceKeys = preferenceKeys
        self.now = now
        self.sleep = sleep
    }
}

/// Mirrors every piece of non-message server state v2 shows into the store.
///
/// One per signed-in login: half of this state is login-scoped (ADR-0079) and the other half
/// comes from routes that answer for every account at once. Views observe the tables;
/// nothing here returns a payload. `docs/architecture/sync-engine.md` § server state is the
/// specification, including the rule that a failed request never deletes a row — which is
/// all "airplane mode keeps the last mirrored state visible" takes.
public actor ServerStateMirror {
    let store: MailStore
    let client: MailClient
    let identity: ServerIdentity
    let configuration: ServerStateConfiguration
    /// Called with the local ids of messages that `checkFollowUps` found answered. Clearing
    /// their `$follow_up` tag is a mutation, so it belongs to the operation queue (WS-22),
    /// which WS-25 wires here.
    let onFollowedUp: @Sendable ([Int64]) async -> Void

    private var conditions = MirrorConditions()
    private var running: Task<ServerStateRefreshReport, Never>?
    private var requests = 0
    private(set) var lastReport: ServerStateRefreshReport?
    /// Triggers that joined a refresh already running, for the debug pane and the test of
    /// exactly that.
    private(set) var joinedRefreshes = 0
    private(set) var outboxPoll: Task<Void, Never>?
    private var outboxPollGeneration = 0

    public init(
        store: MailStore,
        client: MailClient,
        identity: ServerIdentity,
        configuration: ServerStateConfiguration = ServerStateConfiguration(),
        onFollowedUp: @escaping @Sendable ([Int64]) async -> Void = { _ in }
    ) {
        self.store = store
        self.client = client
        self.identity = identity
        self.configuration = configuration
        self.onFollowedUp = onFollowedUp
    }

    deinit {
        running?.cancel()
        outboxPoll?.cancel()
    }

    // MARK: - Triggers

    /// Refreshes every kind. A trigger arriving while a refresh runs joins it — Settings
    /// opening during the launch refresh gets the launch refresh's rows, not a second pass.
    @discardableResult
    public func refresh(trigger: ServerStateTrigger) async -> ServerStateRefreshReport {
        if let running {
            joinedRefreshes += 1
            return await running.value
        }
        guard !conditions.isOffline else {
            var report = ServerStateRefreshReport(trigger: trigger)
            report.skippedOffline = true
            return report
        }
        let task = Task { await self.run(trigger: trigger) }
        running = task
        let report = await task.value
        running = nil
        lastReport = report
        return report
    }

    /// Re-reads the outbox now. The outbox engine (WS-23) calls this after it enqueues,
    /// sends or deletes; the poll calls it every minute while the outbox is non-empty.
    public func refreshOutbox() async {
        guard !conditions.isOffline, let accounts = try? await store.accounts(identity: identity) else { return }
        do {
            if try await replaceOutbox(accounts: accounts) > 0 { startOutboxPoll() }
        } catch {
            MirrorLog.mirror.info("outbox refresh failed: \(describe(error), privacy: .public)")
        }
    }

    /// Asks the server which of these follow-up reminders have been answered, when Priority
    /// inbox shows its follow-up section. One `followUp` row per message.
    ///
    /// - Parameter messageIds: local message ids, the ones on screen.
    public func checkFollowUps(messageIds: [Int64]) async {
        guard !conditions.isOffline, !messageIds.isEmpty else { return }
        do {
            let writer = ServerResultWriter(store: store, loginId: try await loginId())
            var remoteToLocal: [Int: Int64] = [:]
            for id in messageIds {
                guard let message = try await store.message(id: id) else { continue }
                remoteToLocal[Int(message.remoteId)] = id
            }
            guard !remoteToLocal.isEmpty else { return }
            let check = try await client.post(
                .followUpCheck,
                body: FollowUpCheckRequest(messageIds: remoteToLocal.keys.sorted())
            )
            let answered = Set(check.data.wasFollowedUp)
            let now = configuration.now()
            for (remote, local) in remoteToLocal {
                try await writer.write(
                    .ready(.object(["wasFollowedUp": .bool(answered.contains(remote))])),
                    kind: .followUp,
                    key: ServerResultKind.messageKey(local),
                    at: now
                )
            }
            let answeredLocal = answered.compactMap { remoteToLocal[$0] }.sorted()
            if !answeredLocal.isEmpty { await onFollowedUp(answeredLocal) }
        } catch {
            MirrorLog.mirror.info("follow-up check failed: \(describe(error), privacy: .public)")
        }
    }

    /// The path monitor. Offline stops the outbox poll and turns every trigger into a no-op;
    /// back online re-reads the outbox if anything was queued, which restarts the poll.
    public func apply(conditions newConditions: MirrorConditions) async {
        let wasOffline = conditions.isOffline
        conditions = newConditions
        if newConditions.isOffline {
            outboxPoll?.cancel()
            outboxPoll = nil
        } else if wasOffline, let queued = try? await store.outboxMessages(), !queued.isEmpty {
            await refreshOutbox()
        }
    }

    // MARK: - The pass

    private func run(trigger: ServerStateTrigger) async -> ServerStateRefreshReport {
        let clock = ContinuousClock()
        let start = clock.now
        requests = 0
        var report = ServerStateRefreshReport(trigger: trigger)
        MirrorLog.mirror.info("server state refresh: \(trigger.rawValue, privacy: .public)")

        let loginId: Int64
        do {
            loginId = try await self.loginId()
        } catch {
            for kind in ServerStateKind.allCases { report.failed[kind] = describe(error) }
            return report
        }

        // The accounts first: every per-account kind below needs the rows, and the Sieve
        // flag it reads is the one this request just brought.
        let accounts = await mirrorAccounts(into: &report)

        // Then everything else, `concurrency` requests at a time. Serially this was 7.3 s on
        // the live server — 25 requests at a ~210 ms PHP floor, plus a 2.4 s IMAP login for
        // the quota — for a refresh that runs at every launch (measured, WS-21).
        var items: [WorkItem] = []
        for account in accounts {
            items += [.quota(account), .delegations(account), .sieve(account)]
        }
        items += [.quickActions, .textBlocks, .trustedSenders, .internalAddresses, .smimeCertificates, .outbox]
        items += configuration.preferenceKeys.map(WorkItem.preference)
        await withTaskGroup(of: ServerStateRefreshReport.self) { group in
            var pending = items[...]
            func next() {
                guard !Task.isCancelled, let item = pending.popFirst() else { return }
                group.addTask { await self.perform(item, accounts: accounts, loginId: loginId) }
            }
            for _ in 0..<max(1, configuration.concurrency) { next() }
            for await partial in group {
                report.merge(partial)
                next()
            }
        }

        report.requests = requests
        report.duration = clock.now - start
        MirrorLog.mirror.info(
            """
            server state refresh done: \(report.refreshed.count, privacy: .public) kinds, \
            \(report.failed.count, privacy: .public) failed, \(report.requests, privacy: .public) requests
            """
        )
        return report
    }

    /// One independent unit of a refresh.
    private enum WorkItem: Sendable {
        case quota(AccountRecord)
        case delegations(AccountRecord)
        case sieve(AccountRecord)
        case quickActions
        case preference(String)
        case textBlocks
        case trustedSenders
        case internalAddresses
        case smimeCertificates
        case outbox
    }

    /// Runs one item into a report of its own, which the pass merges: concurrent items
    /// cannot share one `inout`.
    private func perform(_ item: WorkItem, accounts: [AccountRecord], loginId: Int64) async -> ServerStateRefreshReport
    {
        var partial = ServerStateRefreshReport(trigger: .launch)
        switch item {
        case .quota(let account): await mirrorQuota(account, loginId: loginId, into: &partial)
        case .delegations(let account): await mirrorDelegations(account, into: &partial)
        case .sieve(let account): await mirrorSieve(account, into: &partial)
        case .quickActions: await mirrorQuickActions(accounts: accounts, into: &partial)
        case .preference(let key): await mirrorPreference(key: key, loginId: loginId, into: &partial)
        case .textBlocks: await mirrorTextBlocks(loginId: loginId, into: &partial)
        case .trustedSenders: await mirrorTrustedSenders(loginId: loginId, into: &partial)
        case .internalAddresses: await mirrorInternalAddresses(loginId: loginId, into: &partial)
        case .smimeCertificates: await mirrorSmimeCertificates(loginId: loginId, into: &partial)
        case .outbox: await mirrorOutbox(accounts: accounts, into: &partial)
        }
        return partial
    }

    /// Runs one kind's work; any throw marks the kind failed and leaves its rows alone.
    private func attempt(
        _ kind: ServerStateKind,
        into report: inout ServerStateRefreshReport,
        _ work: () async throws -> Void
    ) async {
        do {
            try await work()
            if report.failed[kind] == nil { report.refreshed.insert(kind) }
        } catch {
            report.refreshed.remove(kind)
            if report.failed[kind] == nil { report.failed[kind] = describe(error) }
            MirrorLog.mirror.info(
                "server state \(kind.rawValue, privacy: .public) failed: \(describe(error), privacy: .public)"
            )
        }
    }

    // MARK: - Accounts

    /// `GET /api/accounts`: settings, signatures and aliases in one request. Answers the
    /// login's account rows — the fresh ones, or the stored ones when the request failed, so
    /// the per-account kinds still run against what is mirrored.
    private func mirrorAccounts(into report: inout ServerStateRefreshReport) async -> [AccountRecord] {
        var records: [AccountRecord] = []
        await attempt(.accounts, into: &report) {
            let payload = try await get(.accounts)
            records = try await store.upsert(
                accounts: try payload.map { try MirrorMapping.accountWrite($0, identity: identity) }
            )
            let byRemote = Dictionary(records.map { ($0.remoteId, $0.id) }, uniquingKeysWith: { first, _ in first })
            for account in payload {
                guard let accountId = byRemote[Int64(account.value.id)] else { continue }
                try await store.replaceAliases(
                    try MirrorMapping.aliasRecords(account, accountId: accountId), accountId: accountId)
            }
        }
        if records.isEmpty {
            records = (try? await store.accounts(identity: identity)) ?? []
        }
        return records
    }

    private func mirrorQuota(
        _ account: AccountRecord, loginId: Int64, into report: inout ServerStateRefreshReport
    ) async {
        await attempt(.quota, into: &report) {
            let quota = try await get(.quota(accountId: Int(account.remoteId))).data
            try await ServerResultWriter(store: store, loginId: loginId).write(
                quotaPayload(quota),
                kind: .quota,
                key: ServerResultKind.accountKey(account.id),
                at: configuration.now()
            )
        }
    }

    private func mirrorDelegations(_ account: AccountRecord, into report: inout ServerStateRefreshReport) async {
        await attempt(.delegations, into: &report) {
            let delegates = try await get(.delegations(accountId: Int(account.remoteId)))
            try await store.replaceDelegations(
                MirrorMapping.delegationRecords(delegates, accountId: account.id),
                accountId: account.id
            )
        }
    }

    /// Only an account with Sieve on is asked: with it off every one of these routes is a
    /// 400 or a 500 (recorded), which would be three wasted requests per account per refresh.
    /// Off is still server state, so the row says so.
    private func mirrorSieve(_ account: AccountRecord, into report: inout ServerStateRefreshReport) async {
        await attempt(.sieve, into: &report) {
            guard account.sieveEnabled else {
                try await store.upsert(
                    sieveState: SieveStateRecord(
                        accountId: account.id, sieveEnabled: false, fetchedAt: configuration.now())
                )
                return
            }
            let remote = Int(account.remoteId)
            var firstError: (any Error)?
            var script: SieveScript??
            var filters: [MailFilter]??
            var outOfOffice: OutOfOfficeState??
            do { script = .some(try await get(.sieveScript(accountId: remote))) } catch { firstError = error }
            do { filters = .some(try await get(.filters(accountId: remote))) } catch {
                firstError = firstError ?? error
            }
            do {
                // `state` is null until out-of-office was ever configured (recorded).
                outOfOffice = .some(try await get(.outOfOffice(accountId: remote)).data.state)
            } catch {
                firstError = firstError ?? error
            }
            let previous = try await store.sieveState(accountId: account.id)
            try await store.upsert(
                sieveState: try MirrorMapping.sieveStateRecord(
                    account: account,
                    script: script,
                    filters: filters,
                    outOfOffice: outOfOffice,
                    previous: previous,
                    fetchedAt: configuration.now()
                )
            )
            // The parts that worked are written; the kind still reports the one that did not.
            if let firstError { throw firstError }
        }
    }

    /// `GET /api/quick-actions` answers for every account; it is grouped by the payload's
    /// server account id, and an account with none gets its list emptied.
    private func mirrorQuickActions(accounts: [AccountRecord], into report: inout ServerStateRefreshReport) async {
        await attempt(.quickActions, into: &report) {
            let actions = try await get(.quickActions).data
            for account in accounts {
                let mine = actions.filter { $0.accountId.map(Int64.init) == account.remoteId }
                let rows = try await store.replaceQuickActions(
                    mine.map { MirrorMapping.quickActionRecord($0, accountId: account.id) },
                    accountId: account.id
                )
                for (action, row) in zip(mine, rows) {
                    guard let quickActionId = row.id else { continue }
                    try await store.replaceQuickActionSteps(
                        MirrorMapping.quickActionStepRecords(action, quickActionId: quickActionId),
                        quickActionId: quickActionId
                    )
                }
            }
        }
    }

    // MARK: - Login-scoped

    /// One key per request: the route has no batch form. A key that fails keeps its last
    /// value; the others still land.
    private func mirrorPreference(key: String, loginId: Int64, into report: inout ServerStateRefreshReport) async {
        await attempt(.preferences, into: &report) {
            let preference = try await get(.preference(key: key))
            let value: String? =
                switch preference.value {
                case .null: nil
                case .array, .object: try MirrorMapping.jsonText(preference.value)
                default: preference.value.stringValue
                }
            try await store.setPreference(key: key, value: value, loginId: loginId, fetchedAt: configuration.now())
        }
    }

    /// All of it is read before any of it is written: replacing the blocks takes their
    /// shares with them, so a share listing that failed halfway must not leave a block
    /// mirrored with its shares gone.
    private func mirrorTextBlocks(loginId: Int64, into report: inout ServerStateRefreshReport) async {
        await attempt(.textBlocks, into: &report) {
            let own = try await get(.textBlocks).data
            let shared = try await get(.sharedTextBlocks).data
            var shares: [Int: [TextBlockShare]] = [:]
            for block in own {
                shares[block.id] = try await get(.textBlockShares(textBlockId: block.id)).data
            }
            let rows = try await store.replaceTextBlocks(
                MirrorMapping.textBlockRecords(own: own, shared: shared, loginId: loginId),
                loginId: loginId
            )
            for row in rows where !row.isShared {
                guard let textBlockId = row.id, let list = shares[Int(row.remoteId)] else { continue }
                try await store.replaceTextBlockShares(
                    MirrorMapping.textBlockShareRecords(list, textBlockId: textBlockId),
                    textBlockId: textBlockId
                )
            }
        }
    }

    private func mirrorTrustedSenders(loginId: Int64, into report: inout ServerStateRefreshReport) async {
        await attempt(.trustedSenders, into: &report) {
            let senders = try await get(.trustedSenders).data
            try await store.replaceTrustedSenders(
                MirrorMapping.trustedSenderRecords(senders, loginId: loginId),
                loginId: loginId
            )
        }
    }

    private func mirrorInternalAddresses(loginId: Int64, into report: inout ServerStateRefreshReport) async {
        await attempt(.internalAddresses, into: &report) {
            let addresses = try await get(.internalAddresses).data
            try await store.replaceInternalAddresses(
                MirrorMapping.internalAddressRecords(addresses, loginId: loginId),
                loginId: loginId
            )
        }
    }

    private func mirrorSmimeCertificates(loginId: Int64, into report: inout ServerStateRefreshReport) async {
        await attempt(.smimeCertificates, into: &report) {
            let certificates = try await get(.smimeCertificates).data
            try await store.replaceSmimeCertificates(
                try MirrorMapping.smimeCertificateRecords(certificates, loginId: loginId),
                loginId: loginId
            )
        }
    }

    // MARK: - Outbox

    private func mirrorOutbox(accounts: [AccountRecord], into report: inout ServerStateRefreshReport) async {
        var queued = 0
        await attempt(.outbox, into: &report) {
            queued = try await replaceOutbox(accounts: accounts)
        }
        if report.failed[.outbox] == nil, queued > 0 { startOutboxPoll() }
    }

    /// `GET /api/outbox` answers for every account; grouped by the payload's server account
    /// id. Answers how many messages are queued across this login's accounts.
    private func replaceOutbox(accounts: [AccountRecord]) async throws -> Int {
        let messages = try await get(.outbox).data.messages
        let now = configuration.now()
        var queued = 0
        for account in accounts {
            let mine = messages.filter { Int64($0.value.accountId) == account.remoteId }
            try await store.replaceOutbox(
                try mine.map { try MirrorMapping.outboxRecord($0, accountId: account.id, syncedAt: now) },
                accountId: account.id
            )
            queued += mine.count
        }
        return queued
    }

    /// Every `outboxPollInterval` while the outbox holds anything; stops by itself the first
    /// time it reads empty. A failed read keeps polling: the rows are still there.
    private func startOutboxPoll() {
        guard outboxPoll == nil else { return }
        outboxPollGeneration += 1
        let generation = outboxPollGeneration
        outboxPoll = Task(priority: .utility) {
            await self.pollOutbox()
            self.outboxPollFinished(generation)
        }
    }

    /// Only the poll that is still current clears the handle; one cancelled by going
    /// offline may finish after a newer one started.
    private func outboxPollFinished(_ generation: Int) {
        if generation == outboxPollGeneration { outboxPoll = nil }
    }

    private func pollOutbox() async {
        while !Task.isCancelled, !conditions.isOffline {
            do {
                try await configuration.sleep(configuration.outboxPollInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, !conditions.isOffline,
                let accounts = try? await store.accounts(identity: identity)
            else { return }
            do {
                if try await replaceOutbox(accounts: accounts) == 0 { return }
            } catch {
                MirrorLog.mirror.info("outbox poll failed: \(describe(error), privacy: .public)")
            }
        }
    }

    // MARK: - Plumbing

    private func get<T: Decodable & Sendable>(_ endpoint: Endpoint<T>) async throws -> T {
        requests += 1
        return try await client.get(endpoint)
    }

    private func loginId() async throws -> Int64 {
        guard let id = try await store.ensureLogin(identity).id else { throw ServerResultError.unknownKey }
        return id
    }
}
