// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

// MARK: - The undo window

extension OutboxSender {
    /// Arms (or re-arms after a relaunch) the timer that ends one draft's undo window.
    func armUndoTimer(_ draftId: Int64, requestedAt: Int64) {
        undoTimers[draftId]?.cancel()
        let remaining = max(0, requestedAt + undoSeconds - configuration.nowSeconds)
        let sleep = configuration.sleep
        undoTimers[draftId] = Task {
            do { try await sleep(.seconds(remaining)) } catch { return }
            await self.undoWindowEnded(draftId)
        }
    }

    private func undoWindowEnded(_ draftId: Int64) async {
        undoTimers.removeValue(forKey: draftId)
        await drain()
    }
}

// MARK: - Draining

extension OutboxSender {
    /// One pass over every row of this account with a `sendState`, oldest request first.
    ///
    /// Undo windows that have ended become `queued` even offline — the window is about the
    /// user, not the network. Everything else needs the network, so offline the pass stops
    /// there and reconnecting starts another.
    func drain() async {
        if isDraining {
            wantsAnotherPass = true
            await drainTask?.value
            return
        }
        isDraining = true
        let task = Task { await self.drainPasses() }
        drainTask = task
        await task.value
        drainTask = nil
        isDraining = false
    }

    private func drainPasses() async {
        repeat {
            wantsAnotherPass = false
            await drainPass()
        } while wantsAnotherPass
    }

    private func drainPass() async {
        let rows: [DraftRecord]
        do {
            rows = try await store.pendingSendDrafts().filter { $0.accountId == accountId }
        } catch {
            OutboxLog.outbox.error("pending sends unreadable: \(Self.logSafe(error), privacy: .public)")
            return
        }
        for row in rows {
            guard let id = row.id, let state = row.sendState.flatMap(DraftSendState.init(rawValue:)) else { continue }
            switch state {
            case .undo:
                await endUndoWindowIfElapsed(row, id: id)
            case .queued, .sending, .closing, .failed:
                break
            }
        }
        guard !isOffline else { return }

        // Re-read: the loop above moved rows from `undo` to `queued`.
        let pending = (try? await store.pendingSendDrafts().filter { $0.accountId == accountId }) ?? []
        for row in pending {
            guard !isOffline, let id = row.id else { return }
            switch row.sendState.flatMap(DraftSendState.init(rawValue:)) {
            case .queued?, .sending?:
                let wentOffline = await serialized(id) { await self.dispatch(id) }
                if wentOffline { return }
            case .closing?:
                await serialized(id) { await self.performClose(id) }
            case .undo?, .failed?, nil:
                continue
            }
        }
    }

    private func endUndoWindowIfElapsed(_ row: DraftRecord, id: Int64) async {
        let requestedAt = row.sendRequestedAt ?? 0
        guard configuration.nowSeconds >= requestedAt + undoSeconds else {
            if undoTimers[id] == nil { armUndoTimer(id, requestedAt: requestedAt) }
            return
        }
        guard !undoing.contains(id) else { return }
        claimed.insert(id)
        do {
            try await store.setDraftSendState(
                id: id,
                sendState: DraftSendState.queued.rawValue,
                sendRequestedAt: row.sendRequestedAt,
                syncError: nil
            )
            OutboxLog.outbox.info("draft \(id, privacy: .public) undo window ended; queued")
        } catch {
            claimed.remove(id)
            OutboxLog.outbox.error("draft \(id, privacy: .public) could not be queued")
        }
    }
}

// MARK: - Dispatch

extension OutboxSender {
    /// Moves one `queued` or `sending` row as far as it can go.
    ///
    /// - Returns: true when the network went away, so the pass should stop.
    func dispatch(_ draftId: Int64) async -> Bool {
        claimed.insert(draftId)
        defer { claimed.remove(draftId) }
        guard let draft = try? await store.draft(id: draftId) else { return false }
        do {
            let remoteId: Int64
            switch draft.sendState.flatMap(DraftSendState.init(rawValue:)) {
            case .queued?:
                remoteId = try await prepare(draft)
            case .sending?:
                guard let pinned = draft.remoteId else {
                    // `sending` is only ever written with a remote id; treat a row that
                    // somehow lacks one as not yet prepared.
                    remoteId = try await prepare(draft)
                    break
                }
                guard let recovered = try await recover(draft, remoteId: pinned) else { return false }
                remoteId = recovered
            default:
                return false
            }
            try await enqueueAndSend(draft, remoteId: remoteId)
            return false
        } catch {
            if Self.isTransport(error) {
                OutboxLog.outbox.info("draft \(draftId, privacy: .public) send waiting for the network")
                return true
            }
            await fail(draftId, error)
            return false
        }
    }

    /// Steps 1 and 2: uploads, then the server draft with `sendAt` set, then `sending`.
    private func prepare(_ draft: DraftRecord) async throws -> Int64 {
        guard let draftId = draft.id else { throw OutboxError.noSuchDraft }
        let remoteId = try await pushDraft(draft, sendAt: serverSendAt(draft), uploadFailureIsFatal: true)
        try await store.setDraftSendState(
            id: draftId,
            sendState: DraftSendState.sending.rawValue,
            sendRequestedAt: draft.sendRequestedAt,
            syncError: nil
        )
        return remoteId
    }

    /// A `sending` row found at launch or after a dropped connection. Its server draft has
    /// `sendAt` set, so the server's draft job never moved it: if it is neither a draft nor
    /// in the outbox, it was sent.
    ///
    /// - Returns: the id to carry on with, or nil when the send already happened (the row
    ///   is gone by then).
    private func recover(_ draft: DraftRecord, remoteId: Int64) async throws -> Int64? {
        guard let draftId = draft.id else { return nil }
        do {
            _ = try await pushDraft(
                draft,
                sendAt: serverSendAt(draft),
                uploadFailureIsFatal: true,
                recreateIfGone: false
            )
            return remoteId
        } catch MailError.notFound {
            // Not a draft any more: it became an outbox message, or it was sent.
        }
        return try await outboxCheck(draftId: draftId, remoteId: remoteId)
    }

    private func outboxCheck(draftId: Int64, remoteId: Int64) async throws -> Int64? {
        do {
            _ = try await client.get(.outboxMessage(id: Int(remoteId)))
            return remoteId
        } catch MailError.notFound {
            OutboxLog.outbox.info("draft \(draftId, privacy: .public) already left the server outbox")
            try await store.deleteDraft(id: draftId)
            await configuration.refreshOutbox()
            return nil
        }
    }

    /// Steps 3 to 5: `from-draft`, the send unless scheduled, the row gone, the hooks.
    private func enqueueAndSend(_ draft: DraftRecord, remoteId: Int64) async throws {
        guard let draftId = draft.id else { return }
        let sendAt = serverSendAt(draft)
        do {
            _ = try await client.post(
                .outboxFromDraft(draftId: Int(remoteId)), body: SendAtRequest(sendAt: Int(sendAt)))
        } catch MailError.notFound {
            // Converted by a previous attempt whose answer was lost: it is in the outbox, or
            // it was sent.
            guard try await outboxCheck(draftId: draftId, remoteId: remoteId) != nil else { return }
        }

        let scheduled = draft.sendAt != nil
        if !scheduled {
            do {
                _ = try await client.post(.sendOutboxMessage(id: Int(remoteId)))
                OutboxLog.outbox.info("draft \(draftId, privacy: .public) sent as outbox \(remoteId, privacy: .public)")
            } catch {
                if Self.isTransport(error) { throw error }
                // The message is the server outbox's now, with its status; the mirrored list
                // shows it and `sendNow`/`copyToSent`/`deleteOutbox` act on it there.
                OutboxLog.outbox.error(
                    "outbox \(remoteId, privacy: .public) send failed: \(Self.logSafe(error), privacy: .public)"
                )
            }
        } else {
            OutboxLog.outbox.info(
                "draft \(draftId, privacy: .public) scheduled as outbox \(remoteId, privacy: .public)")
        }
        try await store.deleteDraft(id: draftId)
        await configuration.refreshOutbox()
        if !scheduled, let sent = try await accountContext().sentMailboxId {
            await configuration.syncMailbox(sent)
        }
    }

    /// The scheduled time, or a short grace ahead of now for an immediate send.
    func serverSendAt(_ draft: DraftRecord) -> Int64 {
        draft.sendAt ?? configuration.nowSeconds + configuration.serverSendGrace.components.seconds
    }

    private func fail(_ draftId: Int64, _ error: any Error) async {
        OutboxLog.outbox.error(
            "draft \(draftId, privacy: .public) send failed: \(Self.logSafe(error), privacy: .public)")
        do {
            try await store.setDraftSendState(
                id: draftId,
                sendState: DraftSendState.failed.rawValue,
                sendRequestedAt: nil,
                syncError: Self.reason(error)
            )
        } catch {
            OutboxLog.outbox.error("draft \(draftId, privacy: .public) failure unrecordable")
        }
    }
}

// MARK: - Server outbox actions

extension OutboxSender {
    func outboxRemoteId(_ outboxId: Int64) async throws -> Int64 {
        guard
            let row = try await store.outboxMessages().first(where: { $0.id == outboxId && $0.accountId == accountId })
        else { throw OutboxError.noSuchOutboxMessage }
        return row.remoteId
    }

    func sendOutboxMessage(_ remoteId: Int64) async throws {
        guard !isOffline else { throw OutboxError.offline }
        do {
            _ = try await client.post(.sendOutboxMessage(id: Int(remoteId)))
        } catch {
            // A failed send changes the row's status on the server; the refresh shows it.
            await configuration.refreshOutbox()
            throw error
        }
        OutboxLog.outbox.info("outbox \(remoteId, privacy: .public) sent")
        await configuration.refreshOutbox()
        if let sent = try await accountContext().sentMailboxId {
            await configuration.syncMailbox(sent)
        }
    }
}
