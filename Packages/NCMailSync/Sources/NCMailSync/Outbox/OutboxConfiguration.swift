// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Timings, the clock and the hooks ``OutboxSender`` needs from outside this folder.
///
/// The hooks are closures rather than references to `SyncScheduler` or `ServerStateMirror`
/// so the sender compiles and tests without either: WS-25 wires them to
/// `SyncScheduler.syncNow(mailboxId:)` and `ServerStateMirror.refreshOutbox()`, which is the
/// only writer of `outboxMessage` (sync-engine.md, "Alongside: server state").
public struct OutboxConfiguration: Sendable {
    /// How long after the last `saveDraft` call the draft is flushed to the server.
    public var saveDebounce: Duration
    /// The undo window. Nothing leaves the machine inside it (ADR-0066).
    public var undoWindow: Duration
    /// How far ahead of now an *immediate* send's server `sendAt` is set. The server's own
    /// job sends due outbox messages, so this is also how long after a crash mid-send the
    /// server finishes the send by itself; and a draft with `sendAt` set is never moved to
    /// IMAP by the server's draft job, which is what pins its id for recovery.
    public var serverSendGrace: Duration
    /// Unix time, injectable so a test can age an undo window without waiting.
    public var now: @Sendable () -> Date
    /// How a debounce or an undo window waits. Throws on cancellation.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// `SyncScheduler.syncNow(mailboxId:)` for this account, with a *local* mailbox id.
    public var syncMailbox: @Sendable (Int64) async -> Void
    /// `ServerStateMirror.refreshOutbox()`.
    public var refreshOutbox: @Sendable () async -> Void

    public init(
        saveDebounce: Duration = .seconds(5),
        undoWindow: Duration = .seconds(10),
        serverSendGrace: Duration = .seconds(60),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        syncMailbox: @escaping @Sendable (Int64) async -> Void = { _ in },
        refreshOutbox: @escaping @Sendable () async -> Void = {}
    ) {
        self.saveDebounce = saveDebounce
        self.undoWindow = undoWindow
        self.serverSendGrace = serverSendGrace
        self.now = now
        self.sleep = sleep
        self.syncMailbox = syncMailbox
        self.refreshOutbox = refreshOutbox
    }

    var nowSeconds: Int64 { Int64(now().timeIntervalSince1970.rounded(.down)) }
}

/// What `draft.sendState` holds. NULL is "an ordinary draft".
public enum DraftSendState: String, Sendable, CaseIterable {
    /// Inside the undo window: nothing has left the machine.
    case undo
    /// The window ended; waiting to be dispatched, which includes waiting to be online.
    case queued
    /// The server draft is up to date with `sendAt` set, so its id is pinned; the next steps
    /// are `from-draft` and the send.
    case sending
    /// Stopped before the server had an outbox message; `syncError` says why. Still a draft.
    case failed
    /// The composer closed while the move to the IMAP Drafts folder could not happen.
    case closing
}

/// Why a send could not even start. Everything that goes wrong later is written to the row.
public enum OutboxError: Error, Sendable, Equatable {
    case noSuchDraft
    case noRecipients
    /// The draft is already in the undo window, queued or sending.
    case alreadySending
    case accountNotMirrored
    case noSuchOutboxMessage
    case offline
}
