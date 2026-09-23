// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// One mailbox, one incremental pass: the bounded window, then the tail scan.
///
/// The two halves are not alternatives. The window is what makes deletions and flag changes
/// visible in seconds; the tail scan is what makes replies visible at all, because
/// `newMessages` contains only the newest message of each thread (`findNewIds` joins the
/// table to itself on `thread_root_id` and keeps rows with no newer sibling). Trust the
/// window alone and a reply to an existing conversation goes missing until the weekly
/// reconcile, which in a mail client is the worst available bug.
extension SyncScheduler {
    func syncOneMailbox(_ mailbox: MailboxRecord, intents: [Int64: PendingIntent]) async {
        guard !shouldStop else { return }
        releaseThrottleIfExpired()
        do {
            var window = LocalWindow(store: store, mailboxId: mailbox.id)
            try await window.ensure(depth: configuration.windowSize)

            if window.rows.isEmpty {
                // Nothing mirrored for this mailbox yet. Sending `ids: []` would be answered
                // from `findAllIds` — the entire mailbox in one unpaginated response — so the
                // window is skipped and the tail scan, which is paged and bounded, does the
                // work instead. On a mailbox the backfill has not reached this is also the
                // polite thing: stage 1 owns the first enumeration.
                SyncLog.sync.debug(
                    "mailbox \(mailbox.id, privacy: .public) has no mirrored rows; window skipped"
                )
            } else {
                try await incremental(mailbox, window: &window, intents: intents)
            }

            guard !shouldStop else { return }
            if sortOrder == .newest {
                try await tailScan(mailbox, window: &window, intents: intents)
            }
            await recordSuccess(mailbox)
        } catch is CancellationError {
            // Quitting, stopping or going offline. Everything written so far is committed.
        } catch MailError.rateLimited(let retryAfter) {
            await applyThrottle(retryAfter: retryAfter)
            await recordFailure(mailbox, MailError.rateLimited(retryAfter: retryAfter))
        } catch {
            await recordFailure(mailbox, error)
        }
    }

    // MARK: - The bounded window

    private func incremental(
        _ mailbox: MailboxRecord,
        window: inout LocalWindow,
        intents: [Int64: PendingIntent]
    ) async throws {
        let claimed = Array(window.rows.prefix(configuration.windowSize))
        let response = try await sendSync(
            mailbox,
            ids: claimed.map { Int($0.remoteId) },
            // Only read when the sort order is oldest-first (`MessageMapper::findNewIds`),
            // and sent regardless so a server that starts honouring it needs no client change.
            lastMessageTimestamp: claimed.map(\.sentAt).min()
        )

        // `changedMessages` is every id sent that still exists — there is no change
        // detection server-side, the source says so in a TODO — so the two lists are applied
        // together. What distinguishes them is only that nothing in `changedMessages` can be
        // new, which is why `bodiesEnqueued` counts unknown ids rather than list membership.
        let envelopes = response.newMessages + response.changedMessages
        if !envelopes.isEmpty {
            try await write(envelopes, mailbox: mailbox, window: &window, intents: intents)
        }

        // `vanishedMessages` is `array_diff(yourIds, stillExisting)` and holds database ids
        // despite the internal name `vanishedMessageUids`, so nothing the client did not
        // claim to know can ever appear here. Measured against the live server: it is also
        // scoped to the mailbox, so a message moved to another folder in the web client is
        // reported vanished from the one it left, and reappears in the destination's own
        // sync with a new id. Deleting the row is therefore right, and the destination's
        // backfill re-fetches the body.
        if !response.vanishedMessages.isEmpty {
            let localIds = response.vanishedMessages.compactMap { window.localId(forRemote: Int64($0)) }
            if !localIds.isEmpty {
                try await store.deleteMessages(ids: localIds)
                window.forget(localIds: localIds)
                countDeletions(mailboxId: mailbox.id, localIds.count)
                SyncLog.sync.info(
                    "mailbox \(mailbox.id, privacy: .public): \(localIds.count, privacy: .public) messages vanished"
                )
            }
        }

        if let stats = response.stats {
            await writeStats(stats, to: mailbox)
        }
    }

    /// `POST /mailboxes/{id}/sync`, answering a 202 by asking again and a 428 by re-priming.
    ///
    /// One loop covers both because both are answered the same way — wait, then try again —
    /// and because the client deliberately does not retry a 202 itself: only the sync engine
    /// knows what window it sent (`networking.md`).
    private func sendSync(
        _ mailbox: MailboxRecord,
        ids: [Int],
        lastMessageTimestamp: Int64?
    ) async throws -> SyncResponse {
        let body = SyncRequest(
            ids: ids,
            lastMessageTimestamp: lastMessageTimestamp.map(Int.init),
            initialise: false,
            sortOrder: sortOrder.rawValue
        )
        for attempt in 0..<max(1, configuration.syncInProgressAttempts) {
            if attempt > 0, let delay = configuration.syncInProgressDelay(beforeAttempt: attempt) {
                try await configuration.sleep(delay)
            }
            try Task.checkCancellation()
            do {
                let response = try await client.post(.sync(mailboxId: Int(mailbox.remoteId)), body: body)
                countRequest(mailboxId: mailbox.id)
                return response
            } catch MailError.syncInProgress {
                countRequest(mailboxId: mailbox.id)
                SyncLog.sync.debug(
                    """
                    mailbox \(mailbox.id, privacy: .public) still syncing server-side, \
                    attempt \(attempt + 1, privacy: .public)
                    """
                )
            } catch MailError.mailboxNotCached {
                countRequest(mailboxId: mailbox.id)
                SyncLog.sync.info("mailbox \(mailbox.id, privacy: .public) not cached; re-priming")
                try await prime(mailbox)
            }
        }
        throw SyncError.primingDidNotFinish(mailboxId: mailbox.id)
    }

    /// `POST /mailboxes/{id}/sync {"ids": [], "init": true}` — the answer to a 428.
    ///
    /// The response carries envelopes free: with an empty `ids` the server answers from
    /// `findAllIds` rather than the thread-head self-join, so none of them stands in for its
    /// replies. They are written; nothing else about the mailbox's enumeration state moves,
    /// because stage 1 owns the cursor (ADR-0030).
    func prime(_ mailbox: MailboxRecord) async throws {
        let response = try await client.post(
            .sync(mailboxId: Int(mailbox.remoteId)),
            body: SyncRequest(ids: [], initialise: true, sortOrder: sortOrder.rawValue)
        )
        countRequest(mailboxId: mailbox.id)
        var window = LocalWindow(store: store, mailboxId: mailbox.id)
        try await window.ensure(depth: configuration.windowSize)
        if !response.newMessages.isEmpty {
            try await write(response.newMessages, mailbox: mailbox, window: &window, intents: [:])
        }
        try await store.setLastPrimedAt(configuration.now(), mailboxId: mailbox.id)
    }

    // MARK: - The tail scan

    /// Pages `GET /messages?view=singleton` from the newest until an entire page is already
    /// known.
    ///
    /// This is what catches the thread siblings `newMessages` omits, and in the steady state
    /// it is exactly one request that finds nothing. The stop condition is "a whole page and
    /// not one id was new" rather than "the first known id", because the server interleaves
    /// by `sentAt` and one known message says nothing about the next.
    private func tailScan(
        _ mailbox: MailboxRecord,
        window: inout LocalWindow,
        intents: [Int64: PendingIntent]
    ) async throws {
        var cursor: Int64?
        var depth = 0
        var pages = 0

        while pages < max(1, configuration.tailScanPageLimit) {
            try Task.checkCancellation()
            guard !shouldStop else { break }

            let page = try await client.get(
                .messages(
                    mailboxId: Int(mailbox.remoteId),
                    cursor: cursor.map(Int.init),
                    limit: configuration.pageSize
                )
            )
            countRequest(mailboxId: mailbox.id)
            pages += 1
            guard !page.isEmpty else { break }

            depth += page.count
            // Slack, because a local row the server has since dropped pushes everything the
            // scan is looking for one place deeper than the server's own count suggests.
            try await window.ensure(depth: depth + configuration.pageSize)

            let unknown = page.filter { !window.knows(remoteId: Int64($0.value.id)) }
            if unknown.isEmpty { break }
            try await write(unknown, mailbox: mailbox, window: &window, intents: intents)
            SyncLog.sync.info(
                """
                mailbox \(mailbox.id, privacy: .public) tail scan page \(pages, privacy: .public): \
                \(unknown.count, privacy: .public) new
                """
            )

            guard let next = Self.nextCursor(after: page, sortOrder: sortOrder), next != cursor else { break }
            cursor = next
            await Task.yield()
        }

        countTailScan(mailboxId: mailbox.id, pages: pages)
        if pages >= max(1, configuration.tailScanPageLimit) {
            SyncLog.sync.error(
                """
                mailbox \(mailbox.id, privacy: .public) tail scan hit its page limit; \
                the rest waits for the deep reconcile
                """
            )
        }
    }

    // MARK: - Cursors

    /// The cursor for the page after `page`, in whichever direction the account's sort order
    /// makes `GET /messages` walk.
    ///
    /// **The `± 1` is the whole point.** The cursor comparison is strict and `dateInt` is not
    /// unique. Under `newest` the server returns messages strictly *older* than the cursor,
    /// so a page ending on one of two messages that share a `dateInt` makes the second
    /// unreachable — permanently, with a 200 and no gap anybody can see. The live inbox has
    /// such a pair, ids 44 and 45 both at 1778515439, and the plain oldest value returns 44
    /// and skips 45. Sending `oldest + 1` re-reads the boundary message, whose upsert finds
    /// the row it already has through `(accountId, remoteId)` and costs nothing.
    ///
    /// Under `oldest` the comparison is the mirror image, measured on the same server:
    /// `cursor=1776198096` returned the messages *newer* than it. So the page walks forward
    /// and the safe cursor is `newest − 1`. ADR-0036.
    static func nextCursor(after page: [RawBacked<Envelope>], sortOrder: NCMailCore.SortOrder) -> Int64? {
        let dates = page.map { Int64($0.value.dateInt) }
        switch sortOrder {
        case .newest: return dates.min().map { $0 + 1 }
        case .oldest: return dates.max().map { $0 - 1 }
        }
    }

    // MARK: - Writing

    /// Maps, masks and upserts a page, then re-reads the queue and repairs anything the user
    /// changed while the write was in flight.
    ///
    /// The repair pass is what stands in for the read of `pendingOperation` *inside* the sync
    /// write transaction that `offline-queue.md` specifies. `MailStore` exposes no way to
    /// open one from here (its `read`/`write` are internal since ADR-0034, correctly), so the
    /// read happens twice instead: once before, and once after. An operation queued during
    /// the window is seen by the second read and its fields re-applied, and one queued after
    /// it wrote the row itself. Either way the user's intent is what ends up in the column.
    /// The real fix is a store DAO and it is in this workstream's report.
    @discardableResult
    func write(
        _ envelopes: [RawBacked<Envelope>],
        mailbox: MailboxRecord,
        window: inout LocalWindow,
        intents: [Int64: PendingIntent]
    ) async throws -> [Int64] {
        let syncedAt = configuration.now()
        let writes = try envelopes.map {
            try MirrorMapping.envelopeWrite(
                $0,
                accountId: accountId,
                mailboxId: mailbox.id,
                syncedAt: syncedAt
            )
        }
        let localIds = writes.map { window.localId(forRemote: $0.remoteId) }
        let masked = SyncConflicts.apply(writes, localIds: localIds, intents: intents)
        let written = try await store.upsert(envelopes: masked)

        countWrites(
            mailboxId: mailbox.id,
            envelopes: masked.count,
            bytes: masked.reduce(into: Int64(0)) { $0 += Int64($1.rawJSON.utf8.count) },
            bodiesEnqueued: localIds.count { $0 == nil }
        )
        window.remember(localIds: written, remoteIds: masked.map(\.remoteId))

        guard drainer != nil else { return written }
        let after = await pendingIntentsByMessage()
        guard !after.isEmpty else { return written }
        let repairs = zip(written, masked).compactMap { localId, write -> EnvelopeWrite? in
            guard let intent = after[localId], intents[localId] != intent else { return nil }
            return SyncConflicts.apply(intent, to: write)
        }
        if !repairs.isEmpty {
            SyncLog.sync.info(
                """
                mailbox \(mailbox.id, privacy: .public): \(repairs.count, privacy: .public) rows \
                repaired from the queue after the write
                """
            )
            try await store.upsert(envelopes: repairs)
        }
        return written
    }

    /// Writes `stats` onto the mailbox row.
    ///
    /// Round-tripped through ``MailboxWrite`` because there is no DAO for two counts, and
    /// the write deliberately omits every mirror-bookkeeping column (ADR-0023), so
    /// `envelopeCursor`, `envelopesComplete` and `lastPrimedAt` cannot be rolled back by it.
    /// A `setMailboxStats` DAO would be one statement instead of fifteen columns; it is in
    /// the report.
    private func writeStats(_ stats: MailboxStats, to mailbox: MailboxRecord) async {
        let write = MailboxWrite(
            accountId: mailbox.accountId,
            remoteId: mailbox.remoteId,
            name: mailbox.name,
            delimiter: mailbox.delimiter,
            displayName: mailbox.displayName,
            specialRole: mailbox.specialRole,
            specialUseJSON: mailbox.specialUseJSON,
            attributesJSON: mailbox.attributesJSON,
            isSubscribed: mailbox.isSubscribed,
            isSelectable: mailbox.isSelectable,
            syncInBackground: mailbox.syncInBackground,
            unreadCount: stats.unread,
            totalCount: stats.total,
            cacheBuster: mailbox.cacheBuster,
            rawJSON: mailbox.rawJSON
        )
        _ = try? await store.upsert(mailboxes: [write], accountId: accountId)
    }
}

/// What the mirror holds for one mailbox, newest first, read as deep as the caller needs.
///
/// Two jobs. It is the window the sync request claims, and it is the membership test the
/// tail scan stops on. Both want the same rows in the same order, and reading them once per
/// pass rather than once per page is the difference between a request per hundred messages
/// and a query per hundred messages.
///
/// It also carries the `remoteId → id` map, which is the only way a `vanishedMessages` entry
/// — a server id — becomes a row this mirror can delete (ADR-0033).
struct LocalWindow {
    let store: MailStore
    let mailboxId: Int64

    private(set) var rows: [MessageRow] = []
    private var localByRemote: [Int64: Int64] = [:]
    private var known: Set<Int64> = []
    private var isExhausted = false
    private var loadedDepth = 0

    init(store: MailStore, mailboxId: Int64) {
        self.store = store
        self.mailboxId = mailboxId
    }

    /// Reads at least the `depth` newest rows, or every row there is.
    mutating func ensure(depth: Int) async throws {
        guard depth > loadedDepth, !isExhausted else { return }
        let fetched = try await store.messages(mailboxId: mailboxId, view: .flat, range: 0..<depth)
        loadedDepth = depth
        isExhausted = fetched.count < depth
        rows = fetched
        localByRemote = Dictionary(fetched.map { ($0.remoteId, $0.id) }, uniquingKeysWith: { first, _ in first })
        // Union rather than replacement: ids learned from a write since the last read are
        // still known, and a re-read would otherwise forget them and re-write their page.
        known.formUnion(fetched.map(\.remoteId))
    }

    func localId(forRemote remoteId: Int64) -> Int64? { localByRemote[remoteId] }

    func knows(remoteId: Int64) -> Bool { known.contains(remoteId) }

    mutating func remember(localIds: [Int64], remoteIds: [Int64]) {
        for (localId, remoteId) in zip(localIds, remoteIds) {
            localByRemote[remoteId] = localId
            known.insert(remoteId)
        }
    }

    mutating func forget(localIds: [Int64]) {
        let gone = Set(localIds)
        for (remoteId, localId) in localByRemote where gone.contains(localId) {
            localByRemote.removeValue(forKey: remoteId)
            known.remove(remoteId)
        }
        rows.removeAll { gone.contains($0.id) }
    }
}
