// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet
public import NCMailStore

/// Drafts and sending for one mail account
/// ([ADR-0066](../../../../../docs/decisions/0066-drafts-and-outbox.md)).
///
/// Not the mutation queue: a send has an undo window, uploads that must finish first, and
/// consequences that cannot be replayed blindly, so its state lives on the `draft` row
/// (`sendState`, `sendRequestedAt`) and this actor moves it along. The full lifecycle is in
/// `sync-engine.md`, "Alongside: drafts and sending".
///
/// Like everything else in this package it writes the database and tells nobody: the
/// composer and the Outbox view observe rows. The methods that throw do so only for "this
/// could not even start"; everything that goes wrong later lands on the row.
public actor OutboxSender {
    let store: MailStore
    let client: MailClient
    let accountId: Int64
    let configuration: OutboxConfiguration

    var isOffline = false
    var isStarted = false

    /// Pending debounced flushes and undo-window timers, by local draft id.
    var saveTimers: [Int64: Task<Void, Never>] = [:]
    var undoTimers: [Int64: Task<Void, Never>] = [:]
    /// The tail of the per-draft serial chain: a flush, a close and a dispatch of one draft
    /// never overlap, which is what keeps a debounce firing mid-send from creating a second
    /// server draft.
    var chains: [Int64: Task<Void, Never>] = [:]
    /// Claimed synchronously, before any await, so `undoSend` and the end of the window
    /// cannot both win.
    var undoing: Set<Int64> = []
    var claimed: Set<Int64> = []

    var isDraining = false
    var wantsAnotherPass = false
    var drainTask: Task<Void, Never>?

    public init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        configuration: OutboxConfiguration = OutboxConfiguration()
    ) {
        self.store = store
        self.client = client
        self.accountId = accountId
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Resumes whatever a quit interrupted: undo windows (elapsed ones dispatch, others wait
    /// out the remainder), queued and half-finished sends, offline closes, and drafts never
    /// flushed.
    public func start() async {
        isStarted = true
        await drain()
        if !isOffline { await flushUnsavedDrafts() }
    }

    /// Cancels timers. Rows keep their state, which is the point: `start()` picks them up.
    public func stop() async {
        isStarted = false
        for task in saveTimers.values { task.cancel() }
        for task in undoTimers.values { task.cancel() }
        saveTimers = [:]
        undoTimers = [:]
    }

    /// The app shell's path monitor, through the same door `SyncScheduler` uses.
    /// Reconnecting dispatches queued sends and flushes dirty drafts.
    public func apply(conditions: MirrorConditions) async {
        let wasOffline = isOffline
        isOffline = conditions.isOffline
        guard wasOffline, !isOffline else { return }
        OutboxLog.outbox.info("account \(self.accountId, privacy: .public) back online; draining outbox")
        await drain()
        await flushUnsavedDrafts()
    }

    // MARK: - Drafts

    /// The composer saved the row. The server hears about it `saveDebounce` after the last
    /// call.
    public func saveDraft(_ draftId: Int64) {
        saveTimers[draftId]?.cancel()
        let delay = configuration.saveDebounce
        let sleep = configuration.sleep
        saveTimers[draftId] = Task {
            do { try await sleep(delay) } catch { return }
            await self.debounceFired(draftId)
        }
    }

    /// The composer closed: flush, move the draft into the IMAP Drafts folder, drop the row.
    public func closeDraft(_ draftId: Int64) async {
        cancelSaveTimer(draftId)
        await serialized(draftId) { await self.performClose(draftId) }
    }

    /// Throws the draft away, here and on the server.
    public func discardDraft(_ draftId: Int64) async {
        cancelSaveTimer(draftId)
        undoTimers.removeValue(forKey: draftId)?.cancel()
        await serialized(draftId) { await self.performDiscard(draftId) }
    }

    // MARK: - Sending

    /// Starts the undo window and returns. Nothing leaves the machine until it ends.
    ///
    /// - Parameter sendAt: a scheduled send; nil sends as soon as the window ends.
    /// - Throws: ``OutboxError`` when the send cannot start — no such draft, no recipient,
    ///   or already sending.
    public func send(draftId: Int64, sendAt: Date?) async throws {
        guard let draft = try await store.draft(id: draftId), draft.accountId == accountId else {
            throw OutboxError.noSuchDraft
        }
        switch draft.sendState.flatMap(DraftSendState.init(rawValue:)) {
        case nil, .failed: break
        case .closing:
            // Reopened and sent before the offline close caught up: sending supersedes it.
            break
        case .undo, .queued, .sending:
            throw OutboxError.alreadySending
        }
        guard try await !store.recipients(draftId: draftId).isEmpty else { throw OutboxError.noRecipients }

        cancelSaveTimer(draftId)
        let requestedAt = configuration.nowSeconds
        // Column-targeted: a composer autosave landing between the read above and this write
        // keeps its content. `sendAt` is pinned here — the one engine write to that column.
        try await store.setDraftSendRequest(
            id: draftId,
            sendAt: sendAt.map { Int64($0.timeIntervalSince1970.rounded(.down)) },
            sendState: DraftSendState.undo.rawValue,
            sendRequestedAt: requestedAt
        )
        OutboxLog.outbox.info(
            "draft \(draftId, privacy: .public) send requested; scheduled \(sendAt != nil, privacy: .public)"
        )
        armUndoTimer(draftId, requestedAt: requestedAt)
    }

    /// Stops a send inside its undo window. The draft is a draft again and nothing reached
    /// the server.
    ///
    /// - Returns: false when it is too late — the window ended and the send is under way.
    @discardableResult
    public func undoSend(draftId: Int64) async -> Bool {
        guard !claimed.contains(draftId), !undoing.contains(draftId) else { return false }
        undoing.insert(draftId)
        defer { undoing.remove(draftId) }
        do {
            guard let draft = try await store.draft(id: draftId),
                draft.sendState == DraftSendState.undo.rawValue,
                let requestedAt = draft.sendRequestedAt,
                configuration.nowSeconds < requestedAt + undoSeconds
            else { return false }
            undoTimers.removeValue(forKey: draftId)?.cancel()
            try await store.setDraftSendState(id: draftId, sendState: nil, sendRequestedAt: nil, syncError: nil)
            OutboxLog.outbox.info("draft \(draftId, privacy: .public) send undone")
            return true
        } catch {
            OutboxLog.outbox.error(
                "draft \(draftId, privacy: .public) undo failed: \(Self.logSafe(error), privacy: .public)")
            return false
        }
    }

    /// Sends a message in the server outbox now: a scheduled one early, or a failed one again.
    ///
    /// - Parameter outboxId: the local `outboxMessage.id`.
    public func sendNow(outboxId: Int64) async throws {
        let remoteId = try await outboxRemoteId(outboxId)
        try await sendOutboxMessage(remoteId)
    }

    /// The server sent the message but could not file it in Sent (status 11). The same
    /// `POST /api/outbox/{id}` resumes the server's chain at the copy step — the web client
    /// does exactly this.
    public func copyToSent(outboxId: Int64) async throws {
        let remoteId = try await outboxRemoteId(outboxId)
        try await sendOutboxMessage(remoteId)
    }

    /// Cancels a message in the server outbox — a scheduled send, or a failed one.
    public func deleteOutbox(outboxId: Int64) async throws {
        let remoteId = try await outboxRemoteId(outboxId)
        guard !isOffline else { throw OutboxError.offline }
        do {
            _ = try await client.delete(.deleteOutboxMessage(id: Int(remoteId)))
        } catch MailError.notFound {
            // Already gone: sent or deleted elsewhere. The refresh below says which.
        }
        await configuration.refreshOutbox()
    }

    // MARK: - Test seam

    /// Waits until every timer, chain and drain started so far has finished.
    func settle() async {
        while true {
            let pending =
                Array(saveTimers.values) + Array(undoTimers.values) + Array(chains.values)
                + (drainTask.map { [$0] } ?? [])
            if pending.isEmpty { return }
            for task in pending { await task.value }
            // Fired timers remove themselves; anything still registered was re-armed.
            if saveTimers.isEmpty, undoTimers.isEmpty, chains.isEmpty, drainTask == nil { return }
        }
    }
}
