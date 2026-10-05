// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore

/// Keeps one account's mirror in step with the server, cheaply and for ever.
///
/// Three loops, described in `docs/architecture/sync-engine.md` and decided in
/// [ADR-0015](../../../../docs/decisions/0015-bounded-sync-window.md):
///
/// 1. **Incremental sync**, every couple of minutes per mailbox. A bounded window of the 250
///    most recent ids, followed by a tail scan that catches the thread siblings
///    `newMessages` structurally omits.
/// 2. **Deep reconcile**, weekly and on demand. A full `view=singleton` enumeration compared
///    against local ids, which is the only thing that catches a message deleted outside the
///    window, a sibling that arrived while the app was closed, or a mailbox re-created
///    server-side with new ids.
/// 3. **Folder-list sync**, hourly. `GET /mailboxes` alongside `GET /accounts`, because
///    `archiveMailboxId` can change under triage.
///
/// Like ``MirrorCoordinator``, nothing here returns a decoded payload to a caller. Every
/// method answers `Void` and everything anybody learns, they learn by reading the database.
/// That is `CLAUDE.md`'s one invariant, and it is the reason a view can never be made to
/// `await` a request by accident.
///
/// **The ordering rule is the single most important thing in this type.** Per account:
/// drain the operation queue, *then* sync, *then* let the backfill have what is left. A sync
/// that runs before the drain overwrites a change the user made and the server has not heard
/// about, and the user watches their archive undo itself.
public actor SyncScheduler {
    let store: MailStore
    let client: MailClient
    /// The mirror's account id. Every request is built from the account row's `remoteId`
    /// instead (ADR-0033).
    let accountId: Int64
    let configuration: SyncConfiguration
    let drainer: (any OperationDraining)?
    /// Woken after a pass that wrote envelopes with no body, so stage 2 picks them up.
    /// Optional because an account whose backfill has finished has no coordinator running.
    let mirror: MirrorCoordinator?

    /// The account row, re-read at the start of each pass. It carries the server id every
    /// endpoint takes and the identity the accounts refresh has to be keyed by.
    private var account: AccountRecord?

    /// The user's server-side sort order, read once per run.
    ///
    /// It is a preference and not a parameter: `GET /messages` ignores a `sortOrder` query
    /// item entirely, measured against the live server. So it decides what a `cursor` means
    /// for everything this type enumerates, and under `oldest` the tail scan is impossible.
    /// [ADR-0036](../../../../docs/decisions/0036-sort-order-decides-the-cursor.md).
    private(set) var sortOrder = NCMailCore.SortOrder.default
    private var hasReadSortOrder = false

    var selectedMailboxId: Int64?
    var conditions = MirrorConditions()
    private var metricsStorage = SyncMetrics()
    private var lastMailboxListSyncAt: Int64?

    private var loopTask: Task<Void, Never>?
    private var isStopped = false

    /// A plain async lock. The three loops must never overlap within one account — that is
    /// the ordering rule — and an actor alone does not give that, because every `await` on a
    /// request is a chance for another call to walk in.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The login's server-state mirror, refreshed at every deep reconcile
    /// (`sync-engine.md` § server state). Shared by every account scheduler of one login.
    let serverState: ServerStateMirror?

    public init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        drainer: (any OperationDraining)? = nil,
        mirror: MirrorCoordinator? = nil,
        serverState: ServerStateMirror? = nil,
        configuration: SyncConfiguration = SyncConfiguration()
    ) {
        self.store = store
        self.client = client
        self.accountId = accountId
        self.drainer = drainer
        self.mirror = mirror
        self.serverState = serverState
        self.configuration = configuration
    }

    deinit {
        loopTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the periodic loop, and runs one pass immediately.
    ///
    /// Safe to call repeatedly: a loop already running is left alone. Nothing about where to
    /// resume is passed in or remembered in memory — what is due is a function of
    /// `mailbox.lastSyncAt`, which is a column.
    public func start() async {
        isStopped = false
        guard loopTask == nil else { return }
        guard !conditions.isOffline else {
            SyncLog.sync.info("account \(self.accountId, privacy: .public) sync not starting: offline")
            return
        }
        loopTask = Task(priority: .utility) { [weak self] in
            await self?.loop()
        }
    }

    /// Stops the periodic loop and asks any pass in flight to stop between units of work.
    ///
    /// Returns once the loop has finished, so "stopped" means stopped rather than stopping.
    /// A pass started by the app's own call to ``syncNow(mailboxId:)`` runs in the app's
    /// task and unwinds at its next checkpoint.
    public func stop() async {
        isStopped = true
        guard let task = loopTask else { return }
        loopTask = nil
        task.cancel()
        await task.value
    }

    /// An explicit refresh: `R`, or the window coming back to the front.
    ///
    /// - Parameter mailboxId: one mailbox, or nil for every mirrored mailbox of the account
    ///   regardless of when it last synced.
    public func syncNow(mailboxId: Int64? = nil) async {
        isStopped = false
        await exclusively {
            await self.pass(mailboxIds: mailboxId.map { [$0] }, forced: true)
        }
    }

    /// A full enumeration compared against local ids: insert what is missing, delete what is
    /// gone, refresh the rest.
    ///
    /// This is **Settings › Storage › Check for missing messages**, and it is also what runs
    /// weekly. It costs `ceil(n/100)` cheap requests per mailbox, so it is not something to
    /// do on a timer any shorter.
    ///
    /// - Parameter mailboxId: one mailbox, or nil for every mirrored mailbox of the account.
    public func deepReconcile(mailboxId: Int64? = nil) async {
        await exclusively {
            await self.reconcilePass(mailboxIds: mailboxId.map { [$0] }, skipSelected: false)
        }
    }

    /// The app shell's one `NWPathMonitor` reporting a change, through the same door
    /// ``MirrorCoordinator/apply(conditions:)`` uses (ADR-0031).
    ///
    /// Offline stops sync entirely — every loop here is a request, and there is nothing
    /// useful to do without one. Reconnecting resumes with an immediate pass, which is what
    /// `sync-engine.md` asks for and what makes closing a laptop a non-event.
    ///
    /// An expensive or constrained path changes nothing: a sync is a few kilobytes and it is
    /// what makes the app correct. Bodies are the megabytes, and pausing those is the
    /// mirror's business, not this one's.
    public func apply(conditions newConditions: MirrorConditions) async {
        guard newConditions != conditions else { return }
        let wasOffline = conditions.isOffline
        conditions = newConditions
        if newConditions.isOffline {
            SyncLog.sync.info("account \(self.accountId, privacy: .public) offline; sync stopping")
            await stop()
        } else if wasOffline {
            SyncLog.sync.info("account \(self.accountId, privacy: .public) back online; syncing now")
            await start()
        }
    }

    /// Which mailbox the user is looking at. It syncs at the foreground interval, and the
    /// weekly reconcile skips it — `sync-engine.md` asks for "never while the user is
    /// actively scrolling that mailbox", and the selection is the only signal of that this
    /// package can see.
    public func setSelectedMailbox(_ mailboxId: Int64?) async {
        selectedMailboxId = mailboxId
    }

    /// Counters for the debug pane. WS-14 asserts on these.
    public var metrics: SyncMetrics { metricsStorage }

    // MARK: - The loop

    private func loop() async {
        while !Task.isCancelled, !isStopped {
            await exclusively {
                await self.pass(mailboxIds: nil, forced: false)
                await self.reconcileIfDue()
            }
            guard !Task.isCancelled, !isStopped else { return }
            do {
                try await configuration.sleep(configuration.tick)
            } catch {
                return
            }
        }
    }

    /// Runs `work` with no other loop of this account in flight.
    private func exclusively(_ work: @Sendable () async -> Void) async {
        while isBusy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        isBusy = true
        await work()
        isBusy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // MARK: - One pass

    /// Drain, then sync, then wake the backfill. In that order, always.
    ///
    /// - Parameters:
    ///   - mailboxIds: the mailboxes to sync, or nil to ask the cadence.
    ///   - forced: an explicit refresh, which ignores both the interval and the failure
    ///     backoff. A user pressing `R` on a mailbox that is backing off means "try it now".
    func pass(mailboxIds: [Int64]?, forced: Bool) async {
        guard !isStopped, !conditions.isOffline else { return }
        let requestsBefore = metricsStorage.requests

        do {
            try await prepare()
        } catch {
            note(error)
            return
        }

        // 1. The drain. Always first: everything below writes the same rows the queue is
        //    holding intents for, and a sync that runs first wins an argument it should lose.
        if let drainer {
            await drainer.drain()
        }
        guard !isStopped else { return }
        let intents = await pendingIntentsByMessage()

        // 2. The folder list, hourly, because a mailbox that no longer exists is a mailbox
        //    not worth syncing and a new one is a mailbox nobody has enumerated.
        if forced || isMailboxListDue() {
            await refreshMailboxList(forceSync: forced)
        }

        // 3. The mailboxes themselves.
        let targets = await resolveTargets(mailboxIds: mailboxIds, forced: forced)
        guard !targets.isEmpty else {
            metricsStorage.requestsInLastCycle = metricsStorage.requests - requestsBefore
            return
        }
        await syncMailboxes(targets, intents: intents)

        // 4. The backfill, last, with whatever is left.
        //
        //    There is no enqueue call, and that is deliberate. Stage 2's queue is
        //    `ORDER BY sentAt DESC` over the rows with no body, so mail that just arrived is
        //    at the head by construction. All this has to do is wake a coordinator that
        //    stopped because its queue had run dry.
        if metricsStorage.bodiesEnqueued > 0, let mirror {
            await mirror.start()
        }

        metricsStorage.cycles += 1
        metricsStorage.requestsInLastCycle = metricsStorage.requests - requestsBefore
    }

    /// The account row and the sort order, both of which decide what every request below
    /// means.
    func prepare() async throws {
        guard let record = try await store.account(id: accountId) else {
            throw SyncError.accountNotMirrored(accountId: accountId)
        }
        account = record
        guard !hasReadSortOrder else { return }
        hasReadSortOrder = true
        do {
            let preference = try await client.get(.preference(key: "sort-order"))
            countRequest()
            sortOrder = NCMailCore.SortOrder(preference: preference)
        } catch {
            // Null is the ordinary answer on an instance where nobody ever set it, and that
            // decodes fine; anything else here is a server that is down, in which case the
            // default is both right and harmless.
            countRequest()
            SyncLog.sync.info(
                "account \(self.accountId, privacy: .public) sort-order unreadable; assuming newest"
            )
        }
        if sortOrder == .oldest {
            metricsStorage.tailScanUnavailable = true
            SyncLog.sync.error(
                """
                account \(self.accountId, privacy: .public) has the server-side sort order set to \
                oldest-first; the tail scan is disabled and thread siblings wait for the deep \
                reconcile. See ADR-0036
                """
            )
        }
    }

    func pendingIntentsByMessage() async -> [Int64: PendingIntent] {
        guard let drainer else { return [:] }
        let intents = await drainer.pendingIntents()
        return Dictionary(intents.map { ($0.messageId, $0) }, uniquingKeysWith: { _, later in later })
    }

    /// Mirrored, selectable mailboxes, filtered by the cadence unless this is an explicit
    /// refresh.
    private func resolveTargets(mailboxIds: [Int64]?, forced: Bool) async -> [MailboxRecord] {
        guard let all = try? await store.mailboxes(accountId: accountId) else { return [] }
        let mirrored = all.filter { $0.isMirrored && $0.isSelectable }
        if let mailboxIds {
            let wanted = Set(mailboxIds)
            return mirrored.filter { wanted.contains($0.id) }
        }
        guard !forced else { return mirrored }

        let cadence = SyncCadence(configuration: configuration)
        let states = mirrored.map { mailbox in
            SyncCadence.MailboxState(
                id: mailbox.id,
                isInbox: mailbox.specialRole?.lowercased() == "inbox",
                lastSuccessAt: metricsStorage.mailboxes[mailbox.id]?.lastSuccessAt ?? mailbox.lastSyncAt,
                nextAttemptAt: metricsStorage.mailboxes[mailbox.id]?.nextAttemptAt
            )
        }
        let dueIds = cadence.due(at: configuration.now(), mailboxes: states, selected: selectedMailboxId)
        let byId = Dictionary(mirrored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return dueIds.compactMap { byId[$0] }
    }

    /// At most ``currentMailboxConcurrency`` at a time, one in as one comes out, so a slow
    /// folder holds one slot rather than the account.
    private func syncMailboxes(_ mailboxes: [MailboxRecord], intents: [Int64: PendingIntent]) async {
        let limit = currentMailboxConcurrency
        await withTaskGroup(of: Void.self) { group in
            var remaining = mailboxes[...]
            for _ in 0..<max(1, limit) {
                guard let next = remaining.popFirst() else { break }
                group.addTask(priority: .utility) { await self.syncOneMailbox(next, intents: intents) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, !isStopped, let next = remaining.popFirst() else { continue }
                group.addTask(priority: .utility) { await self.syncOneMailbox(next, intents: intents) }
            }
        }
    }

    /// Three by default, halved while a 429 or a 503 cooldown is in force.
    ///
    /// Deliberately its own limit and **not** a draw on ``MirrorBudget/shared``, which is the
    /// four-body cap. A body fetch holds its slot for 1.37 s on average (measured by WS-04
    /// over 155 real messages); making a sync queue behind four of them would put the "new
    /// mail appears immediately on `R`" promise several seconds behind a backfill that may
    /// run for hours. ADR-0035 has the argument and the alternative.
    var currentMailboxConcurrency: Int {
        guard metricsStorage.throttledUntil != nil else { return configuration.mailboxConcurrency }
        return max(1, configuration.mailboxConcurrency / 2)
    }

    // MARK: - Folder list

    private func isMailboxListDue() -> Bool {
        guard let last = lastMailboxListSyncAt else { return true }
        return configuration.now() - last >= configuration.mailboxListInterval
    }

    /// `GET /mailboxes` and `GET /accounts`.
    ///
    /// - Parameter forceSync: only on an explicit user refresh. It makes the server re-read
    ///   the folder list from IMAP, which is not something to do hourly on someone else's
    ///   machine.
    private func refreshMailboxList(forceSync: Bool) async {
        guard let account else { return }
        do {
            let accounts = try await client.get(.accounts)
            countRequest()
            try await store.upsert(
                accounts: try accounts.map { try MirrorMapping.accountWrite($0, identity: account.identity) }
            )
        } catch {
            note(error)
        }
        guard !isStopped else { return }
        do {
            let list = try await client.get(
                .mailboxes(accountId: Int(account.remoteId), forceSync: forceSync)
            )
            countRequest()
            try await store.upsert(
                mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: accountId) },
                accountId: accountId
            )
            lastMailboxListSyncAt = configuration.now()
        } catch {
            note(error)
        }
    }

    // MARK: - The weekly reconcile

    private static func reconcileKey(_ accountId: Int64) -> String { "sync.lastDeepReconcile.\(accountId)" }

    private func reconcileIfDue() async {
        guard !isStopped, !conditions.isOffline else { return }
        let now = configuration.now()
        let last = await storedLastReconcile()
        metricsStorage.lastDeepReconcileAt = last
        guard let last else {
            // Never reconciled. Stamp it rather than running one the moment the app opens:
            // the mirror has just been built by the backfill, which enumerated everything,
            // so the first useful reconcile is a week from now.
            try? await store.setMetaValue(String(now), forKey: Self.reconcileKey(accountId))
            metricsStorage.lastDeepReconcileAt = now
            return
        }
        guard now - last >= configuration.deepReconcileInterval else { return }
        await reconcilePass(mailboxIds: nil, skipSelected: true)
    }

    private func storedLastReconcile() async -> Int64? {
        guard let text = (try? await store.metaValue(forKey: Self.reconcileKey(accountId))) ?? nil else {
            return nil
        }
        return Int64(text)
    }

    func recordReconcileFinished() async {
        let now = configuration.now()
        try? await store.setMetaValue(String(now), forKey: Self.reconcileKey(accountId))
        metricsStorage.lastDeepReconcileAt = now
    }

    // MARK: - Metrics and bookkeeping

    func countRequest(mailboxId: Int64? = nil) {
        metricsStorage.requests += 1
        guard let mailboxId else { return }
        metricsStorage.mailboxes[mailboxId, default: MailboxSyncMetrics()].requests += 1
    }

    func countWrites(mailboxId: Int64, envelopes: Int, bytes: Int64, bodiesEnqueued: Int) {
        metricsStorage.envelopesWritten += envelopes
        metricsStorage.envelopeBytesDown += bytes
        metricsStorage.bodiesEnqueued += bodiesEnqueued
        metricsStorage.mailboxes[mailboxId, default: MailboxSyncMetrics()].envelopesWritten += envelopes
    }

    func countDeletions(mailboxId: Int64, _ count: Int) {
        metricsStorage.messagesDeleted += count
        metricsStorage.mailboxes[mailboxId, default: MailboxSyncMetrics()].messagesDeleted += count
    }

    func countTailScan(mailboxId: Int64, pages: Int) {
        metricsStorage.mailboxes[mailboxId, default: MailboxSyncMetrics()].lastTailScanPages = pages
    }

    /// A mailbox worked. Clears its failure count both in memory and in the row, and stamps
    /// `lastSyncAt` so the cadence knows when it last ran.
    func recordSuccess(_ mailbox: MailboxRecord) async {
        let now = configuration.now()
        var entry = metricsStorage.mailboxes[mailbox.id] ?? MailboxSyncMetrics()
        entry.lastSuccessAt = now
        entry.lastError = nil
        entry.consecutiveFailures = 0
        entry.nextAttemptAt = nil
        metricsStorage.mailboxes[mailbox.id] = entry
        // `setEnvelopeCursor` is the DAO that stamps `lastSyncAt` and clears
        // `syncFailureCount` and `lastSyncError`, which is exactly what a successful sync
        // means. Its cursor and completion arguments are passed back unchanged: stage 1 owns
        // those (ADR-0030) and sync must not move them.
        try? await store.setEnvelopeCursor(
            mailbox.envelopeCursor,
            complete: mailbox.envelopesComplete,
            mailboxId: mailbox.id,
            lastSyncAt: now
        )
    }

    /// A mailbox failed. It backs off, it is marked in the row, and **the account carries
    /// on**: `sync-engine.md` is explicit that one failing mailbox never blocks another,
    /// never clears what is mirrored, and never turns into a modal. A 401 is the one the app
    /// turns into its session-expired modal, from the `unauthorized` this writes to the row.
    func recordFailure(_ mailbox: MailboxRecord, _ error: any Error) async {
        let description = describeSync(error)
        var entry = metricsStorage.mailboxes[mailbox.id] ?? MailboxSyncMetrics()
        entry.consecutiveFailures += 1
        entry.lastError = description
        entry.nextAttemptAt = configuration.now() + configuration.failureBackoff(after: entry.consecutiveFailures)
        metricsStorage.mailboxes[mailbox.id] = entry
        metricsStorage.lastError = description
        SyncLog.sync.error(
            """
            mailbox \(mailbox.id, privacy: .public) sync failed \
            \(entry.consecutiveFailures, privacy: .public)×: \(description, privacy: .public)
            """
        )
        try? await store.recordSyncFailure(mailboxId: mailbox.id, message: description)
    }

    /// A 429 or a 503. Halves mailbox concurrency for ten minutes and waits out
    /// `Retry-After` once more, so the other workers do not walk into the same wall.
    func applyThrottle(retryAfter: Duration?) async {
        let until = configuration.now() + configuration.throttleCooldownSeconds
        if metricsStorage.throttledUntil == nil {
            SyncLog.sync.error(
                """
                account \(self.accountId, privacy: .public) throttled; sync concurrency halved for \
                \(self.configuration.throttleCooldownSeconds, privacy: .public)s
                """
            )
        }
        metricsStorage.throttledUntil = max(metricsStorage.throttledUntil ?? until, until)
        try? await configuration.sleep(retryAfter ?? .seconds(1))
    }

    func releaseThrottleIfExpired() {
        guard let until = metricsStorage.throttledUntil, configuration.now() >= until else { return }
        metricsStorage.throttledUntil = nil
        SyncLog.sync.info("account \(self.accountId, privacy: .public) throttle lifted")
    }

    func note(_ error: any Error) {
        let description = describeSync(error)
        metricsStorage.lastError = description
        SyncLog.sync.error("account \(self.accountId, privacy: .public): \(description, privacy: .public)")
    }

    var shouldStop: Bool { isStopped || conditions.isOffline || Task.isCancelled }

    /// The server's id for this account, for building a request. Nil only before the first
    /// successful ``prepare()``.
    var remoteAccountId: Int64? { account?.remoteId }
}

/// `describe(_:)` from the mirror, plus this package's own sync error, whose cases name a
/// mailbox id and nothing else.
func describeSync(_ error: any Error) -> String {
    if let error = error as? SyncError { return error.description }
    return describe(error)
}

/// What the scheduler itself can fail with, as opposed to what the server answered.
public enum SyncError: Error, Sendable, CustomStringConvertible {
    /// Built for an account id the mirror has no row for. The row comes first — see
    /// ``MirrorCoordinator/discoverAccounts(store:client:identity:)``.
    case accountNotMirrored(accountId: Int64)
    /// Stage 0 answered 202 or 428 more times than ``SyncConfiguration/syncInProgressAttempts``
    /// allows. The mailbox keeps everything it has and is tried again next cycle.
    case primingDidNotFinish(mailboxId: Int64)

    public var description: String {
        switch self {
        case .accountNotMirrored(let accountId): "accountNotMirrored(account: \(accountId))"
        case .primingDidNotFinish(let mailboxId): "primingDidNotFinish(mailbox: \(mailboxId))"
        }
    }
}
