// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailNet
public import NCMailStore

/// Replays the queue to the server, one operation at a time, for ever.
///
/// One in flight per account and in `id` order, because mail actions are causally ordered —
/// star, then move, then delete — and parallelising them buys milliseconds while risking a
/// wrong final state.
///
/// Nothing here sleeps. A backoff is `nextAttemptAt` on the row, not a suspended task, so
/// quitting the app loses no work and relaunching three days later resumes exactly where it
/// left off. ``drain()`` returns as soon as there is nothing ready, and something — an
/// action, a reconnect, the sync loop — wakes it again.
///
/// Like every other type in this package it returns `Void` and tells nobody anything. What
/// changed, changed in the database.
public actor OperationDrainer: OperationDraining {
    private let store: MailStore
    private let client: MailClient
    private let accountId: Int64
    private let configuration: MutationQueueConfiguration

    /// One pass at a time. A second `wake` during a pass sets ``wantsAnotherPass`` rather
    /// than starting a second drain, which is how "one in flight per account" survives an
    /// action arriving mid-drain.
    private var isDraining = false
    private var wantsAnotherPass = false
    private var subscribers: [UUID: AsyncStream<PendingSummary>.Continuation] = [:]
    private var lastSummary = PendingSummary()
    /// So a 403 is reported once per account rather than once per operation.
    private var hasReportedForbidden = false

    public init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        configuration: MutationQueueConfiguration = MutationQueueConfiguration()
    ) {
        self.store = store
        self.client = client
        self.accountId = accountId
        self.configuration = configuration
    }

    // MARK: - Surfacing

    /// The queue depth and the failures, republished after every change.
    ///
    /// `offline-queue.md` derives the count from a database observation. This publishes it
    /// from the drainer instead, because `NCMailStore` exposes `pendingOperations(accountId:)`
    /// as a read and not as a `StoreObservation`. The values are identical; only the delivery
    /// differs, and the document says so.
    ///
    /// Each iteration gets the current summary immediately, so a view that subscribes late
    /// draws the right thing without waiting for the next change.
    public nonisolated var pendingCount: AsyncStream<PendingSummary> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
            Task { await self.addSubscriber(id, continuation) }
        }
    }

    private func addSubscriber(_ id: UUID, _ continuation: AsyncStream<PendingSummary>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(lastSummary)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// The summary as the database has it right now. Also refreshes what subscribers see.
    @discardableResult
    public func summary() async -> PendingSummary {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        return publish(OperationCollapse.collapse(rows))
    }

    /// Publishes the summary of `work` without going back to the database.
    ///
    /// The drain already holds the list, and re-reading the queue after every operation was
    /// half of what made a thousand of them take a minute.
    @discardableResult
    private func publish(_ work: [CollapsedOperation]) -> PendingSummary {
        // `offline-queue.md`'s count is `state != 'inFlight' AND attempts >= 5`: an
        // operation being sent right now is not a failure, however many times it failed
        // before.
        let failing = work.filter { !$0.isInFlight && $0.attempts >= configuration.visibleAfterAttempts }
        let summary = PendingSummary(
            queued: work.count,
            failing: failing.count,
            failures: failing.map {
                PendingFailure(
                    id: $0.id,
                    kind: $0.kind,
                    messageId: $0.messageId,
                    attempts: $0.attempts,
                    lastError: $0.lastError
                )
            }
        )
        lastSummary = summary
        for continuation in subscribers.values { continuation.yield(summary) }
        return summary
    }

    // MARK: - OperationDraining

    /// The fields a not-yet-sent operation owns, so a sync does not overwrite them.
    ///
    /// Collapsed first, so star-unstar-star answers the final state rather than three
    /// intents, and merged across rows so one message yields one intent.
    public func pendingIntents() async -> [PendingIntent] {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        var byMessage: [Int64: [String: Bool]] = [:]
        for item in OperationCollapse.collapse(rows) {
            guard !item.payload.flags.isEmpty, let messageId = item.messageId else { continue }
            byMessage[messageId, default: [:]].merge(item.payload.flags) { _, later in later }
        }
        return
            byMessage
            .map { PendingIntent(messageId: $0.key, flags: $0.value) }
            .sorted { $0.messageId < $1.messageId }
    }

    /// Sends everything that is ready, oldest first, and returns when nothing more can go.
    ///
    /// "Nothing more" is the queue being empty, everything left waiting out a backoff, the
    /// network being gone, or the session having expired. None of those is an error here:
    /// the rows keep their state and the next wake tries again.
    public func drain() async {
        guard !isDraining else {
            wantsAnotherPass = true
            return
        }
        isDraining = true
        defer { isDraining = false }

        repeat {
            wantsAnotherPass = false
            await onePass()
        } while wantsAnotherPass && !Task.isCancelled
    }

    /// One collapse, then one request per work item, in order.
    ///
    /// The collapse happens **once per pass** and not once per request, which is the one
    /// place this departs from `offline-queue.md`'s wording. Re-reading and re-collapsing the
    /// whole queue before every request made a thousand queued operations take 52.4 seconds
    /// against a transport that answers instantly; doing it once takes 0.45-0.8. Nothing is lost:
    /// an operation queued during the pass wakes the drainer, which runs another pass, and
    /// the only thing it misses is the chance to fold into an item already being sent.
    private func onePass() async {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        var work = OperationCollapse.collapse(rows)
        publish(work)

        var index = 0
        while index < work.count, !Task.isCancelled {
            let item = work[index]
            guard item.nextAttemptAt.map({ $0 <= configuration.now() }) ?? true else {
                index += 1
                continue
            }
            do {
                try await store.markInFlight(ids: item.absorbedIds)
            } catch {
                OperationLog.queue.error("queue claim failed: \(describeOperation(error), privacy: .public)")
                return
            }
            let outcome = await attempt(item)
            if outcome.resolved {
                work.remove(at: index)
            } else {
                work[index].attempts = outcome.attempts
                index += 1
            }
            publish(work)
            guard outcome.carryOn else { return }
        }
    }

    /// What one attempt left behind.
    private struct Outcome {
        /// The rows are gone from the queue, whether sent, dropped or discarded.
        var resolved: Bool
        /// The operation's attempt count now, for the indicator.
        var attempts: Int
        /// Whether the pass should try the next operation.
        var carryOn: Bool
    }

    /// One request and what it left behind.
    private func attempt(_ item: CollapsedOperation) async -> Outcome {
        do {
            try await send(item)
            try await store.finish(ids: item.absorbedIds, applying: [])
            OperationLog.queue.info(
                """
                operation \(item.id, privacy: .public) \(item.kind.rawValue, privacy: .public) sent, \
                \(item.absorbedIds.count, privacy: .public) row(s) cleared
                """
            )
            return Outcome(resolved: true, attempts: item.attempts, carryOn: true)
        } catch let error as MailError {
            // A cancelled request surfaces as a transport failure, because that is what the
            // client saw. It is not the operation's fault and must not count against it.
            if case .transport = error, Task.isCancelled {
                await releaseClaim(item)
                return Outcome(resolved: false, attempts: item.attempts, carryOn: false)
            }
            return await handle(error, for: item)
        } catch is CancellationError {
            await releaseClaim(item)
            return Outcome(resolved: false, attempts: item.attempts, carryOn: false)
        } catch {
            return await handle(.transport(error), for: item)
        }
    }

    private func handle(_ error: MailError, for item: CollapsedOperation) async -> Outcome {
        switch error {
        case .notFound:
            // The message is gone server-side. Drop the operation *and* the local row: the
            // user's change is moot and the mirror is simply behind. No error is shown —
            // `offline-queue.md` is explicit that this is the quiet path.
            //
            // This is also what cleans up a row orphaned by a message deleted elsewhere:
            // `pendingOperation.messageId` has no foreign key, so nothing else would.
            await resolve(item, applying: [LocalEffect(messageIds: touchedMessages(item), removesRows: true)])
            OperationLog.queue.info("operation \(item.id, privacy: .public) dropped: message gone server-side")
            return Outcome(resolved: true, attempts: item.attempts, carryOn: true)

        case .forbidden:
            // A 403 for a stale id is the ordinary answer, not a lost session: the Mail app
            // answers 403 for any id the user may not see, which includes one that no longer
            // exists. So the row goes, the account is re-read, and nothing signs anybody out.
            await resolve(item, applying: [])
            if !hasReportedForbidden {
                hasReportedForbidden = true
                OperationLog.queue.error("account \(self.accountId, privacy: .public) refused an operation (403)")
            }
            await configuration.refreshAccount?(accountId)
            return Outcome(resolved: true, attempts: item.attempts, carryOn: true)

        case .server(let status, _) where status == 409 || status == 412:
            // The server has moved on. Let it win, drop the row, and re-read the mailbox the
            // message came from so the mirror learns what actually happened.
            await resolve(item, applying: [])
            if let mailboxId = item.payload.before.mailboxIds.values.first ?? item.payload.destinationMailboxId {
                await configuration.forceSync?(mailboxId)
            }
            OperationLog.queue.info("operation \(item.id, privacy: .public) conflicted (\(status, privacy: .public))")
            return Outcome(resolved: true, attempts: item.attempts, carryOn: true)

        case .rateLimited(let retryAfter):
            // Not a failure. The server asked for patience and got it, and the attempt count
            // is left alone so a busy server never pushes an operation into the indicator.
            let seconds = retryAfter.map { Int64($0.components.seconds) } ?? 1
            try? await store.reschedule(
                ids: item.absorbedIds,
                attempts: nil,
                nextAttemptAt: configuration.now() + max(1, seconds),
                lastError: nil
            )
            OperationLog.queue.info("queue throttled for \(seconds, privacy: .public)s")
            return Outcome(resolved: false, attempts: item.attempts, carryOn: false)

        case .unauthorized:
            // Signing in again belongs to the login flow. Nothing is counted against the
            // operation, because the operation is not what is wrong.
            try? await store.reschedule(ids: item.absorbedIds, attempts: nil, nextAttemptAt: nil, lastError: nil)
            OperationLog.queue.error("account \(self.accountId, privacy: .public) queue paused: unauthorized")
            return Outcome(resolved: false, attempts: item.attempts, carryOn: false)

        default:
            let attempts = await recordFailure(item, error)
            // A 5xx is about this request; the next message may well work. A transport
            // failure is about the network, and nothing else will work until it is back.
            if case .transport = error {
                return Outcome(resolved: false, attempts: attempts, carryOn: false)
            }
            return Outcome(resolved: false, attempts: attempts, carryOn: true)
        }
    }

    /// Puts a claimed operation back, in a task of its own.
    ///
    /// Cancellation is the reason for the extra task. The enclosing task is already being
    /// torn down, and a database write from a cancelled task can be refused — which would
    /// leave the row marked `inFlight` with nothing in flight.
    private func releaseClaim(_ item: CollapsedOperation) async {
        let store = store
        let ids = item.absorbedIds
        await Task {
            try? await store.reschedule(ids: ids, attempts: nil, nextAttemptAt: nil, lastError: nil)
        }
        .value
    }

    @discardableResult
    private func recordFailure(_ item: CollapsedOperation, _ error: MailError) async -> Int {
        let attempts = item.attempts + 1
        try? await store.reschedule(
            ids: item.absorbedIds,
            attempts: attempts,
            nextAttemptAt: configuration.now() + configuration.backoff(after: attempts),
            lastError: error.description
        )
        OperationLog.queue.error(
            """
            operation \(item.id, privacy: .public) failed \(attempts, privacy: .public)×: \
            \(error.description, privacy: .public)
            """
        )
        return attempts
    }

    private func resolve(_ item: CollapsedOperation, applying effects: [LocalEffect]) async {
        do {
            try await store.finish(ids: item.absorbedIds, applying: effects)
        } catch {
            OperationLog.queue.error("queue cleanup failed: \(describeOperation(error), privacy: .public)")
        }
    }

    /// The local rows an operation touched, for the branches that have to undo or erase them.
    private func touchedMessages(_ item: CollapsedOperation) -> [Int64] {
        item.payload.before.messageIds.isEmpty
            ? item.messageId.map { [$0] } ?? []
            : item.payload.before.messageIds
    }

    // MARK: - Requests

    private func send(_ item: CollapsedOperation) async throws {
        guard let remoteId = item.payload.remoteId else {
            // A row with no server id cannot be sent and never will be. Dropping it is the
            // only outcome that does not wedge the queue behind it.
            throw MailError.notFound
        }
        switch item.kind {
        case .setFlags:
            _ = try await client.put(
                Endpoint.setFlags(messageId: Int(remoteId)),
                body: SetFlagsRequest(flags: item.payload.flags)
            )
        case .move:
            _ = try await client.post(
                Endpoint.moveMessage(id: Int(remoteId)),
                // `destFolderId` here, `destMailboxId` on the thread route below. Same
                // concept, two spellings, both upstream's.
                body: MoveMessageRequest(destFolderId: Int(try await remoteMailboxId(item)))
            )
        case .delete:
            _ = try await client.delete(Endpoint.deleteMessage(id: Int(remoteId)))
        case .moveThread:
            _ = try await client.post(
                Endpoint.moveThread(messageId: Int(remoteId)),
                body: MoveThreadRequest(destMailboxId: Int(try await remoteMailboxId(item)))
            )
        case .deleteThread:
            _ = try await client.delete(Endpoint.deleteThread(messageId: Int(remoteId)))
        }
    }

    /// The server's id for a move destination, resolved at send time from the local id the
    /// row stores (ADR-0033).
    private func remoteMailboxId(_ item: CollapsedOperation) async throws -> Int64 {
        guard
            let localId = item.payload.destinationMailboxId,
            let mailbox = try await store.mailbox(id: localId)
        else {
            // The destination is not in the mirror any more. There is no request to make and
            // no id to guess, so the operation is dropped the same way a vanished message is.
            throw MailError.notFound
        }
        return mailbox.remoteId
    }

    // MARK: - The popover's two buttons

    /// **Retry now.** Clears every wait so the next pass takes everything, then runs one.
    ///
    /// The attempt counts stay. A retry that fails again should not have quietly reset the
    /// indicator the user pressed it from.
    public func retryAll() async {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        let ids = rows.compactMap(\.id)
        guard !ids.isEmpty else { return }
        try? await store.reschedule(ids: ids, attempts: nil, nextAttemptAt: nil, lastError: nil)
        await drain()
    }

    /// **Discard.** Drops the operation and puts the mirror back where it was.
    ///
    /// - Parameter operationId: the id from ``PendingSummary/failures``, which is the oldest
    ///   row of a collapsed group. Discarding it discards the whole group, because the group
    ///   is what the user was shown and reverting half of star-unstar-star would leave the
    ///   screen in a state nobody asked for.
    ///
    /// One case cannot be reverted: a `delete` of a message that was already in trash erased
    /// the row, and there is nothing left to restore. The operation is dropped and the next
    /// sync brings the message back, because the server was never told. `offline-queue.md`
    /// records that exception.
    public func discard(operationId: Int64) async {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        guard let item = OperationCollapse.collapse(rows).first(where: { $0.absorbedIds.contains(operationId) })
        else { return }

        await resolve(item, applying: reversal(of: item))
        OperationLog.queue.info(
            "operation \(item.id, privacy: .public) discarded, \(item.absorbedIds.count, privacy: .public) row(s)"
        )
        await summary()
    }

    /// Drops every queued operation for this account and reverts each one.
    ///
    /// The **Discard** answer to signing out with a non-empty queue
    /// ([offline-queue.md](../../../../docs/architecture/offline-queue.md#sign-out-and-pending-work)).
    /// Newest first, so a message moved twice ends up where it started rather than where the
    /// first of the two moves left it.
    public func discardAll() async {
        let rows = (try? await store.pendingOperations(accountId: accountId)) ?? []
        for item in OperationCollapse.collapse(rows).reversed() {
            await resolve(item, applying: reversal(of: item))
        }
        await summary()
    }

    /// The effects that put the mirror back to ``OperationPayload/before``.
    private func reversal(of item: CollapsedOperation) -> [LocalEffect] {
        guard !item.payload.erases else { return [] }
        var effects: [LocalEffect] = []

        if !item.payload.before.flags.isEmpty {
            effects.append(
                LocalEffect(messageIds: touchedMessages(item), flags: item.payload.before.flags)
            )
        }
        // One effect per source mailbox: a move that gathered messages from three folders
        // puts each one back where it came from, not all three into the first.
        let byMailbox = Dictionary(grouping: item.payload.before.mailboxIds.keys) { messageId in
            item.payload.before.mailboxIds[messageId]
        }
        for (mailboxId, messageIds) in byMailbox {
            guard let mailboxId else { continue }
            effects.append(LocalEffect(messageIds: messageIds.sorted(), mailboxId: mailboxId))
        }
        return effects
    }

    // MARK: - Waking

    /// Called after a commit, a reconnect, or a sync pass. Starts a drain if one is not
    /// already running, and marks one to follow if it is.
    public func wake() {
        guard !isDraining else {
            wantsAnotherPass = true
            return
        }
        Task { [weak self] in
            await self?.drain()
        }
    }
}

/// `describe(_:)` for this file's catch sites.
func describeOperation(_ error: any Error) -> String {
    if let error = error as? OperationError { return error.description }
    return describe(error)
}
