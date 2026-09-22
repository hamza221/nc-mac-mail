// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
public import NCMailNet
public import NCMailStore

/// Fills the local mirror for one account, from a fresh sign-in to a complete copy.
///
/// Three stages, described in `docs/architecture/local-mirror.md`: prime the server's IMAP
/// cache, enumerate envelopes, then download bodies newest-first across every mailbox of
/// the account. All of the progress lives in the database — `mailbox.envelopeCursor`,
/// `mailbox.envelopesComplete`, `message.bodyState` — so ``start()`` resumes wherever the
/// last run stopped and a `kill -9` costs at most the page in flight.
///
/// This is the only type in the application that sees a `MailClient` and a `MailStore` at
/// once, and it writes exclusively to the second. Nothing here returns a decoded payload to
/// a caller: the views read the database, and the database is how they learn anything
/// happened.
///
/// One coordinator per account. Accounts run in parallel; ``MirrorBudget/shared`` is what
/// stops four of them asking the server for eight bodies at a time.
public actor MirrorCoordinator {
    let store: MailStore
    let client: MailClient
    let accountId: Int64
    let configuration: MirrorConfiguration
    let accountBudget: MirrorBudget
    let globalBudget: MirrorBudget

    /// The latest count of what is mirrored, recomputed from the rows rather than tallied
    /// in a variable, so it is right after a crash and right after a restore.
    ///
    /// Single-consumer, like every `AsyncStream`: the app-side glue reads it and assigns
    /// into `AppStatus.mirror` on the main actor. It buffers the newest element only — a
    /// progress count that arrived two seconds ago is not worth showing once a newer one
    /// exists, and an unbounded buffer would grow while nobody is looking at the sidebar.
    public nonisolated let progress: AsyncStream<MirrorProgress>
    nonisolated let progressContinuation: AsyncStream<MirrorProgress>.Continuation

    private var runTask: Task<Void, Never>?
    private var powerObserver: Task<Void, Never>?
    private var runGeneration = 0
    private var isUserPaused = false
    var conditions = MirrorConditions()
    private var hadUnrecoverableFailure = false

    /// Stage 2's queue. In memory and never written to the database: a claimed id that is
    /// only claimed in memory goes back to being `missing` for free when the app is killed,
    /// whereas a `queued` row would have to be swept up at the next launch by something
    /// that could itself be interrupted.
    var pendingBodyIds: [Int64] = []
    var inFlightBodyIds: Set<Int64> = []
    var isBodyQueueExhausted = false
    var bodyFailureCounts: [Int64: Int] = [:]
    var bodiesSincePublish = 0
    /// Unix seconds. While set, body concurrency is halved (etiquette rule 3).
    var throttledUntil: Int64?

    public init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        configuration: MirrorConfiguration = MirrorConfiguration()
    ) {
        self.init(
            store: store,
            client: client,
            accountId: accountId,
            configuration: configuration,
            globalBudget: .shared
        )
    }

    /// - Parameter globalBudget: the four-in-total cap. Injected so a test can assert on a
    ///   budget nothing else in the process is drawing from.
    init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        configuration: MirrorConfiguration,
        globalBudget: MirrorBudget
    ) {
        self.store = store
        self.client = client
        self.accountId = accountId
        self.configuration = configuration
        self.globalBudget = globalBudget
        accountBudget = MirrorBudget(limit: configuration.bodyConcurrency)
        (progress, progressContinuation) = AsyncStream.makeStream(
            of: MirrorProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        runTask?.cancel()
        powerObserver?.cancel()
        progressContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts, or resumes, the backfill. Safe to call repeatedly: a run already in progress
    /// is left alone rather than duplicated.
    ///
    /// Nothing about where to restart is passed in. The mailboxes still to enumerate and
    /// the messages still missing a body are both database queries, which is what makes
    /// "quit mid-backfill and relaunch" a non-event.
    public func start() async {
        startPowerObserver()
        guard runTask == nil else { return }
        isUserPaused = await storedPauseFlag()
        await publishProgress()
        if let reason = runPauseReason {
            MirrorLog.mirror.info(
                "account \(self.accountId, privacy: .public) not starting: \(reason.rawValue, privacy: .public)"
            )
            await setState(.paused)
            return
        }
        runGeneration += 1
        let generation = runGeneration
        runTask = Task(priority: .utility) { await self.run(generation: generation) }
    }

    /// The user pressed Pause backfill. Persisted in `meta`, so it survives a relaunch and
    /// the mirror does not quietly start again on the next launch.
    public func pause() async {
        isUserPaused = true
        try? await store.setMetaValue("1", forKey: Self.pauseKey(accountId))
        await stopRun()
        await setState(.paused)
        await publishProgress()
    }

    public func resume() async {
        isUserPaused = false
        try? await store.setMetaValue(nil, forKey: Self.pauseKey(accountId))
        await start()
    }

    /// The app shell's one `NWPathMonitor` reporting a change.
    ///
    /// Offline stops the whole mirror and reconnecting restarts it; an expensive or
    /// constrained network stops stage 2 only, because stage 1 is a few kilobytes per
    /// hundred messages and it is what makes the app usable.
    public func apply(conditions newConditions: MirrorConditions) async {
        guard newConditions != conditions else { return }
        conditions = newConditions
        if newConditions.stopsEverything {
            await stopRun()
            await setState(.paused)
        } else if !isUserPaused {
            await start()
        }
        await publishProgress()
    }

    /// Why the mirror is not doing everything it could, for the sidebar footer. Nil when it
    /// is working or has finished.
    ///
    /// Low Power Mode and a metered network appear here even though stage 1 carries on
    /// under both: S-02 asks the progress UI to say why bodies have stopped, and "still
    /// enumerating, bodies held for Low Power Mode" is the truth the user needs.
    public var pauseReason: MirrorPauseReason? { bodyPauseReason }

    /// What stops the whole mirror. Only two things do: the user, and having no network at
    /// all. Etiquette rule 4 is explicit that the rest pause stage 2 and never stage 1,
    /// because enumerating is cheap and it is what makes the app usable.
    var runPauseReason: MirrorPauseReason? {
        if isUserPaused { return .userRequested }
        if conditions.isOffline { return .offline }
        return nil
    }

    /// Stage 2's current per-account limit. Two normally, one while a 429 or 503 cooldown
    /// is in force.
    public var bodyConcurrencyLimit: Int {
        get async { await accountBudget.currentLimit }
    }

    /// Watches Low Power Mode, because nothing else does.
    ///
    /// `NWPathMonitor` lives in the app shell and reports the path; the power state is a
    /// separate fact with its own notification, and without this the mirror would stop when
    /// the battery got low and stay stopped after the user plugged in.
    private func startPowerObserver() {
        guard powerObserver == nil else { return }
        let notifications = NotificationCenter.default.notifications(
            named: NSNotification.Name.NSProcessInfoPowerStateDidChange
        )
        powerObserver = Task { [weak self] in
            for await _ in notifications {
                guard let self else { return }
                await self.powerStateChanged()
            }
        }
    }

    func powerStateChanged() async {
        MirrorLog.mirror.info(
            """
            account \(self.accountId, privacy: .public) power state changed, \
            low power \(self.configuration.isLowPowerModeEnabled(), privacy: .public)
            """
        )
        if runTask == nil, runPauseReason == nil, bodyPauseReason == nil {
            await start()
        }
        await publishProgress()
    }

    /// Waits for the current pass to finish, without asking it to stop.
    ///
    /// The app never needs this — it watches ``progress`` — but a test that asserts on what
    /// a whole backfill wrote has to know when the backfill is over, and the alternative is
    /// polling the database on a timer, which is the sleeping test
    /// `docs/architecture/concurrency.md` forbids.
    func awaitCurrentRun() async {
        await runTask?.value
    }

    private func stopRun() async {
        guard let task = runTask else { return }
        runTask = nil
        task.cancel()
        // Wait for it, so that "paused" means stopped rather than stopping. Every loop in
        // here checks cancellation between units of work and every request is cancellable,
        // so this returns in the time of one in-flight response at worst.
        await task.value
    }

    private static func pauseKey(_ accountId: Int64) -> String { "mirror.paused.\(accountId)" }

    private func storedPauseFlag() async -> Bool {
        ((try? await store.metaValue(forKey: Self.pauseKey(accountId))) ?? nil) == "1"
    }

    // MARK: - The run

    private func run(generation: Int) async {
        hadUnrecoverableFailure = false
        MirrorLog.mirror.info("mirror starting for account \(self.accountId, privacy: .public)")
        do {
            try await bootstrap()
            try await runEnvelopeStage()
            try await runBodyStage()
        } catch is CancellationError {
            MirrorLog.mirror.info("mirror cancelled for account \(self.accountId, privacy: .public)")
        } catch {
            hadUnrecoverableFailure = true
            MirrorLog.mirror.error(
                "mirror stopped for account \(self.accountId, privacy: .public): \(describe(error), privacy: .public)"
            )
        }
        await publishProgress()
        await settleState()
        // Only if this is still the current run. A pause that cancelled us has already
        // cleared the slot and a later start may have filled it again.
        if generation == runGeneration { runTask = nil }
    }

    /// `GET /accounts` then `GET /mailboxes?accountId=`, both upserted.
    ///
    /// A failure here is not fatal. Everything after this point reads the mailbox list from
    /// the database, so a relaunch with no network resumes the backfill of what is already
    /// known rather than refusing to do anything.
    private func bootstrap() async throws {
        try Task.checkCancellation()
        await setState(.priming)
        do {
            let accounts = try await client.get(.accounts)
            try await store.upsert(accounts: accounts.map(MirrorMapping.accountWrite))
        } catch let error as MailError {
            try rethrowIfUnrecoverable(error)
            MirrorLog.mirror.error("accounts refresh failed: \(describe(error), privacy: .public)")
        }

        try Task.checkCancellation()
        do {
            let list = try await client.get(.mailboxes(accountId: Int(accountId)))
            try await store.upsert(
                mailboxes: list.entries.map(MirrorMapping.mailboxWrite),
                accountId: accountId
            )
            MirrorLog.mirror.info(
                """
                account \(self.accountId, privacy: .public): \
                \(list.entries.count, privacy: .public) mailboxes, \
                \(list.entries.filter(\.value.isSubscribed).count, privacy: .public) subscribed
                """
            )
        } catch let error as MailError {
            try rethrowIfUnrecoverable(error)
            MirrorLog.mirror.error("mailbox refresh failed: \(describe(error), privacy: .public)")
        }
    }

    /// 401 means the app password is gone and nothing else will work either. Everything
    /// else — including a 403, which the Mail app answers for any id the caller may not
    /// see, and which a mirror provokes constantly once someone deletes a message in the
    /// web client — is a fact about one request and never a reason to stop the mirror or to
    /// sign anybody out.
    private func rethrowIfUnrecoverable(_ error: MailError) throws {
        guard case .unauthorized = error else { return }
        throw error
    }

    // MARK: - Stages 0 and 1

    /// Mirrored, selectable mailboxes whose enumeration has not finished, inbox first.
    ///
    /// The order is the whole of "the inbox's first page is readable well before the mirror
    /// completes": with two mailboxes enumerated at a time, putting the inbox first means
    /// its first hundred rows land in the first round trip.
    private func backlogMailboxes() async throws -> [MailboxRecord] {
        let all = try await store.mailboxes(accountId: accountId)
        return
            all
            .filter { $0.isMirrored && $0.isSelectable && !$0.envelopesComplete }
            .sorted { lhs, rhs in
                let left = Self.rolePriority(lhs.specialRole)
                let right = Self.rolePriority(rhs.specialRole)
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static let roleOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]

    private static func rolePriority(_ role: String?) -> Int {
        guard let role, let index = roleOrder.firstIndex(of: role.lowercased()) else {
            return roleOrder.count
        }
        return index
    }

    private func runEnvelopeStage() async throws {
        let mailboxes = try await backlogMailboxes()
        guard !mailboxes.isEmpty else { return }
        await setState(.envelopes)

        await withTaskGroup(of: Void.self) { group in
            var remaining = mailboxes[...]
            for _ in 0..<max(1, configuration.mailboxConcurrency) {
                guard let next = remaining.popFirst() else { break }
                group.addTask(priority: .utility) { await self.mirrorMailbox(next) }
            }
            // One mailbox in, one mailbox out, so a slow folder holds one slot rather than
            // the account. `local-mirror.md`: one slow mailbox never blocks the account.
            while await group.next() != nil {
                guard !Task.isCancelled, let next = remaining.popFirst() else { continue }
                group.addTask(priority: .utility) { await self.mirrorMailbox(next) }
            }
        }
        try Task.checkCancellation()
    }

    private func mirrorMailbox(_ mailbox: MailboxRecord) async {
        do {
            if mailbox.lastPrimedAt == nil {
                try await prime(mailboxId: mailbox.id)
            }
            try await enumerate(mailbox)
        } catch is CancellationError {
            // Quitting, pausing or going offline. Everything written so far is committed.
        } catch {
            MirrorLog.mirror.error(
                """
                mailbox \(mailbox.id, privacy: .public) left behind this pass: \
                \(describe(error), privacy: .public)
                """
            )
            try? await store.recordSyncFailure(mailboxId: mailbox.id, message: describe(error))
        }
    }

    /// Stage 0. `POST /mailboxes/{id}/sync {"ids": [], "init": true}`.
    ///
    /// The server refuses to enumerate a mailbox its own IMAP cache has not seen, so this
    /// is mandatory and not an optimisation. A 202 means it accepted the work and is still
    /// doing it; a 428 means the cache went away again. Both are answered by asking again
    /// with `init: true`, which is why one loop covers them.
    private func prime(mailboxId: Int64) async throws {
        for attempt in 0..<max(1, configuration.primeAttempts) {
            if attempt > 0, let delay = configuration.primeDelay(beforeAttempt: attempt) {
                try await configuration.sleep(delay)
            }
            try Task.checkCancellation()
            do {
                let response = try await client.post(
                    .sync(mailboxId: Int(mailboxId)),
                    body: SyncRequest(ids: [], initialise: true)
                )
                try await storePrimed(response, mailboxId: mailboxId)
                return
            } catch MailError.syncInProgress {
                MirrorLog.mirror.debug(
                    "mailbox \(mailboxId, privacy: .public) still priming, attempt \(attempt + 1, privacy: .public)"
                )
            } catch MailError.mailboxNotCached {
                MirrorLog.mirror.debug(
                    "mailbox \(mailboxId, privacy: .public) not cached, re-priming"
                )
            }
        }
        throw MirrorError.primingDidNotFinish(mailboxId: mailboxId)
    }

    /// The priming response carries envelopes, free: with an empty `ids` the server answers
    /// from `findAllIds` rather than the thread-head self-join that makes `newMessages`
    /// lossy elsewhere, so every one of them is real and none is a thread head standing in
    /// for its replies. Measured against the live server: mailbox 5, 95 messages, 95
    /// envelopes back.
    ///
    /// The cursor is deliberately not advanced from them. Stage 1 still starts at its
    /// stored cursor and re-reads its first page, which costs one cheap database read on
    /// the server and removes the need to trust that "all" means all on a mailbox large
    /// enough for the server to decide otherwise.
    private func storePrimed(_ response: SyncResponse, mailboxId: Int64) async throws {
        let syncedAt = configuration.now()
        let writes = try response.newMessages.map {
            try MirrorMapping.envelopeWrite($0, accountId: accountId, syncedAt: syncedAt)
        }
        if !writes.isEmpty {
            try await store.upsert(envelopes: writes)
        }
        // `lastPrimedAt` has no DAO of its own — `MailboxWrite` deliberately omits every
        // mirror-bookkeeping column (ADR-0023) and `setEnvelopeCursor` covers the others.
        // Raw SQL through the store's own writer rather than a column the folder refresh
        // could roll back; asked of WS-03 in the report.
        try await store.write { database in
            try database.execute(
                sql: "UPDATE mailbox SET lastPrimedAt = ? WHERE id = ?",
                arguments: [syncedAt, mailboxId]
            )
        }
        MirrorLog.mirror.info(
            "mailbox \(mailboxId, privacy: .public) primed, \(writes.count, privacy: .public) envelopes free"
        )
        await publishProgress()
    }

    /// Stage 1. Pages of a hundred envelopes, oldest-ward, until a short page.
    ///
    /// Envelopes are written before the cursor moves, and that order is the guarantee: a
    /// crash in between re-fetches one page, whose upserts land identically. The reverse
    /// order would advance past messages that were never stored, and nothing downstream
    /// would ever notice the hole. See ADR-0030.
    private func enumerate(_ mailbox: MailboxRecord) async throws {
        var cursor = mailbox.envelopeCursor
        let limit = configuration.envelopePageSize

        while true {
            try Task.checkCancellation()
            if conditions.stopsEverything { return }

            let page = try await fetchEnvelopePage(mailboxId: mailbox.id, cursor: cursor)
            let syncedAt = configuration.now()
            let writes = try page.map {
                try MirrorMapping.envelopeWrite($0, accountId: accountId, syncedAt: syncedAt)
            }
            var isComplete = page.count < limit

            if !writes.isEmpty {
                try await store.upsert(envelopes: writes)
            }

            // One past the oldest `dateInt`, not the oldest `dateInt`. The server's cursor
            // is strictly exclusive — measured: asking with the oldest value returns
            // messages *older* than it, never it — so two messages sharing a `dateInt`
            // across a page boundary lose the second one, permanently and silently. The
            // live inbox has such a pair (ids 44 and 45, both 1778515439) and the
            // documented algorithm drops id 45. Overlapping by one `dateInt` re-reads the
            // boundary message, whose upsert is a no-op, and costs at most one duplicated
            // row per page. ADR-0030.
            let nextCursor = writes.map(\.sentAt).min().map { $0 + 1 } ?? cursor

            // A full page that did not move the cursor would ask for the same page forever.
            // It takes a hundred messages sharing one second to happen; stopping loses less
            // than spinning does, and the deep reconcile (WS-05) finds what was left.
            if !isComplete, nextCursor == cursor {
                MirrorLog.mirror.error(
                    "mailbox \(mailbox.id, privacy: .public) cursor did not advance; ending this pass"
                )
                isComplete = true
            }
            cursor = nextCursor

            try await store.setEnvelopeCursor(
                cursor,
                complete: isComplete,
                mailboxId: mailbox.id,
                lastSyncAt: syncedAt
            )
            await publishProgress()

            if isComplete {
                MirrorLog.mirror.info("mailbox \(mailbox.id, privacy: .public) enumerated")
                return
            }
            await Task.yield()
        }
    }

    /// One page, re-priming once if the server has forgotten the mailbox mid-enumeration.
    private func fetchEnvelopePage(mailboxId: Int64, cursor: Int64?) async throws -> [RawBacked<Envelope>] {
        let endpoint = Endpoint.messages(
            mailboxId: Int(mailboxId),
            cursor: cursor.map(Int.init),
            limit: configuration.envelopePageSize
        )
        do {
            return try await client.get(endpoint)
        } catch MailError.mailboxNotCached {
            MirrorLog.mirror.info(
                "mailbox \(mailboxId, privacy: .public) fell out of the server cache mid-page; re-priming"
            )
            try await prime(mailboxId: mailboxId)
            return try await client.get(endpoint)
        }
    }

    // MARK: - Progress and state

    func publishProgress() async {
        guard let snapshot = try? await store.mirrorProgress(accountId: accountId) else { return }
        progressContinuation.yield(snapshot)
    }

    private func setState(_ state: MirrorState) async {
        try? await store.setMirrorState(state, accountId: accountId, lastSyncAt: configuration.now())
    }

    private func settleState() async {
        let snapshot = try? await store.mirrorProgress(accountId: accountId)
        if snapshot?.isComplete == true {
            await setState(.complete)
            MirrorLog.mirror.info("mirror complete for account \(self.accountId, privacy: .public)")
        } else if hadUnrecoverableFailure {
            await setState(.failed)
        } else {
            await setState(.paused)
        }
    }
}

/// What the coordinator itself can fail with, as opposed to what the server answered.
public enum MirrorError: Error, Sendable, CustomStringConvertible {
    /// Stage 0 ran out of attempts against a 202 or a 428. The mailbox keeps everything it
    /// already has and is tried again on the next pass.
    case primingDidNotFinish(mailboxId: Int64)

    public var description: String {
        switch self {
        case .primingDidNotFinish(let mailboxId): "primingDidNotFinish(mailbox: \(mailboxId))"
        }
    }
}

/// A log- and column-safe rendering of any error.
///
/// `MailError` already promises to describe itself without anything a user wrote;
/// everything else is reduced to its type name rather than its message, because a
/// `DatabaseError` or a `URLError` can carry a path or a host.
func describe(_ error: any Error) -> String {
    switch error {
    case let error as MailError: error.description
    case let error as MirrorError: error.description
    case is CancellationError: "cancelled"
    default: String(describing: type(of: error))
    }
}
