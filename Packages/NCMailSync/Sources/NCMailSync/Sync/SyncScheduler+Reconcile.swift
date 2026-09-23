// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

/// The safety net: a full `view=singleton` enumeration compared against local ids.
///
/// It is the only thing that catches a structural hole, and `sync-engine.md` lists four of
/// them — a message deleted in the web client outside the 250-message window, a thread
/// sibling that arrived while the app was closed and fell outside it, anything lost to a
/// crash between two pages of the original backfill, and a mailbox re-created server-side
/// with new ids. None of those is visible to the incremental loop by construction, not by
/// accident, which is why the reconcile is not optional.
extension SyncScheduler {
    func reconcilePass(mailboxIds: [Int64]?, skipSelected: Bool) async {
        guard !shouldStop else { return }
        do {
            try await prepare()
        } catch {
            note(error)
            return
        }

        // The ordering rule holds here too. A reconcile writes every row of a mailbox, so a
        // queued change it has not heard about is exactly as vulnerable as under a sync.
        if let drainer {
            await drainer.drain()
        }
        let intents = await pendingIntentsByMessage()

        guard let all = try? await store.mailboxes(accountId: accountId) else { return }
        var targets = all.filter { $0.isMirrored && $0.isSelectable }
        if let mailboxIds {
            let wanted = Set(mailboxIds)
            targets = targets.filter { wanted.contains($0.id) }
        } else if skipSelected, let selected = selectedMailboxId {
            // "Never while the user is actively scrolling that mailbox." The selection is
            // the only signal of that this package can see, and the mailbox comes round again
            // next week or the moment the user asks from Settings.
            targets = targets.filter { $0.id != selected }
        }
        guard !targets.isEmpty else { return }

        SyncLog.sync.info(
            """
            account \(self.accountId, privacy: .public) deep reconcile over \
            \(targets.count, privacy: .public) mailboxes
            """
        )
        for mailbox in targets {
            guard !shouldStop else { break }
            await reconcile(mailbox, intents: intents)
        }
        await recordReconcileFinished()
    }

    private func reconcile(_ mailbox: MailboxRecord, intents: [Int64: PendingIntent]) async {
        releaseThrottleIfExpired()
        do {
            let enumeration = try await enumerateServer(mailbox, intents: intents)
            guard enumeration.isComplete else {
                // A partial walk says nothing about what is missing. Deleting from it would
                // remove every message below the page the walk stopped on, which is the one
                // way this routine could destroy a mirror rather than repair one.
                SyncLog.sync.error(
                    "mailbox \(mailbox.id, privacy: .public) reconcile incomplete; nothing deleted"
                )
                return
            }
            try await removeAndRetry(mailbox, serverIds: enumeration.remoteIds)
            await recordSuccess(mailbox)
        } catch is CancellationError {
        } catch MailError.rateLimited(let retryAfter) {
            await applyThrottle(retryAfter: retryAfter)
            await recordFailure(mailbox, MailError.rateLimited(retryAfter: retryAfter))
        } catch {
            await recordFailure(mailbox, error)
        }
    }

    private struct Enumeration {
        var remoteIds: Set<Int64> = []
        var isComplete = false
    }

    /// Every message the server has in this mailbox, page by page, written as it goes.
    ///
    /// Writing each page rather than collecting and writing once is what makes a reconcile
    /// interrupted half way still worth having: the refreshed flags and the inserted
    /// messages are committed, and only the deletion half is skipped.
    private func enumerateServer(
        _ mailbox: MailboxRecord,
        intents: [Int64: PendingIntent]
    ) async throws -> Enumeration {
        var result = Enumeration()
        var cursor: Int64?
        var window = LocalWindow(store: store, mailboxId: mailbox.id)
        try await window.ensure(depth: configuration.windowSize)

        while true {
            try Task.checkCancellation()
            guard !shouldStop else { return result }

            let page = try await client.get(
                .messages(
                    mailboxId: Int(mailbox.remoteId),
                    cursor: cursor.map(Int.init),
                    limit: configuration.pageSize
                )
            )
            countRequest(mailboxId: mailbox.id)
            result.remoteIds.formUnion(page.map { Int64($0.value.id) })

            if !page.isEmpty {
                try await window.ensure(depth: result.remoteIds.count + configuration.pageSize)
                try await write(page, mailbox: mailbox, window: &window, intents: intents)
            }

            if page.count < configuration.pageSize {
                result.isComplete = true
                return result
            }

            // The same `± 1` stage 1 uses, and for the same reason. `sync-engine.md` says
            // the reconcile enumerates "exactly as stage 1", and stage 1 means `oldest
            // dateInt + 1`: the cursor is strictly exclusive and two messages can share a
            // `dateInt`, so the plain oldest value skips the second of the pair. A reconcile
            // built to find missing mail that carried that blind spot would be worse than
            // none — it would report the mirror complete while the hole it was written to
            // find stayed open. ADR-0030, and trap 5 in `api-payloads.md`.
            guard let next = Self.nextCursor(after: page, sortOrder: sortOrder), next != cursor else {
                // A full page that did not move the cursor takes a hundred messages sharing
                // one second. Stopping loses less than spinning, and nothing is deleted from
                // an incomplete walk.
                SyncLog.sync.error(
                    "mailbox \(mailbox.id, privacy: .public) reconcile cursor did not advance"
                )
                return result
            }
            cursor = next
            await Task.yield()
        }
    }

    /// Deletes what the server no longer has, and re-queues the bodies that gave up.
    ///
    /// The second half is the other promise `local-mirror.md` makes about this routine: a
    /// body that failed three times is marked `failed` and "retried on the next deep
    /// reconcile, not in a tight loop". This is that reconcile.
    private func removeAndRetry(_ mailbox: MailboxRecord, serverIds: Set<Int64>) async throws {
        var stale: [Int64] = []
        var failedBodies: [Int64] = []
        var offset = 0
        let chunk = 1_000

        while true {
            try Task.checkCancellation()
            let rows = try await store.messages(
                mailboxId: mailbox.id,
                view: .flat,
                range: offset..<(offset + chunk)
            )
            for row in rows {
                if serverIds.contains(row.remoteId) {
                    if row.bodyState == .failed { failedBodies.append(row.id) }
                } else {
                    stale.append(row.id)
                }
            }
            if rows.count < chunk { break }
            offset += chunk
        }

        if !stale.isEmpty {
            try await store.deleteMessages(ids: stale)
            countDeletions(mailboxId: mailbox.id, stale.count)
            SyncLog.sync.info(
                """
                mailbox \(mailbox.id, privacy: .public) reconcile removed \
                \(stale.count, privacy: .public) messages the server no longer has
                """
            )
        }
        if !failedBodies.isEmpty {
            try await store.setBodyState(.missing, messageIds: failedBodies)
            SyncLog.sync.info(
                """
                mailbox \(mailbox.id, privacy: .public) reconcile re-queued \
                \(failedBodies.count, privacy: .public) failed bodies
                """
            )
            if let mirror { await mirror.start() }
        }
    }
}
