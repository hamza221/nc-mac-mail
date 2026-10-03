// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What the sync engine has done, per account and per mailbox.
///
/// `sync-engine.md` asks for these by name, and the reason is in the sentence before the
/// list: sync bugs are invisible without them. A mirror that quietly stops finding replies
/// looks exactly like a mirror with nothing to find, and the only difference visible from
/// outside is a request count that stopped moving.
///
/// Counters, not a log. Everything here is a number or an error *description*, which
/// `MailError` already promises to render without anything a user wrote, so the whole value
/// is safe to show in a debug pane and safe to interpolate into `OSLog` as `.public`.
public struct SyncMetrics: Sendable, Equatable {
    /// Completed passes, whether or not they found anything.
    public var cycles = 0
    /// Every request the engine has sent: syncs, tail-scan pages, reconcile pages, and the
    /// folder-list refresh.
    public var requests = 0
    /// Requests sent by the most recently finished pass. The steady-state number the brief
    /// asks to be constant per mailbox regardless of mirror size.
    public var requestsInLastCycle = 0
    /// Envelopes handed to `MailStore.upsert(envelopes:)`, new and refreshed alike.
    public var envelopesWritten = 0
    /// Rows removed because the server no longer has them.
    public var messagesDeleted = 0
    /// Envelopes written whose body the mirror does not hold, so the backfill will fetch
    /// them. Stage 2 orders by `sentAt DESC`, so new mail is at the head by construction
    /// rather than by an enqueue call — see ``SyncScheduler``.
    public var bodiesEnqueued = 0
    /// Bytes of envelope JSON received.
    ///
    /// Not the transfer size: `MailClient` hands back a decoded value and never the response
    /// length, so this sums the `rawJSON` each envelope carries. That is the payload and
    /// within a few per cent of the body of the response, and it is the only honest number
    /// available without widening `NCMailNet`.
    public var envelopeBytesDown: Int64 = 0
    /// A 429 or a 503 is in force and mailbox concurrency is halved until this unix second.
    public var throttledUntil: Int64?
    /// The last failure of any kind, for the debug pane's one-line summary.
    public var lastError: String?
    /// Set once per account when the tail scan is impossible because the user's server-side
    /// sort order is oldest-first. See ADR-0036.
    public var tailScanUnavailable = false
    public var lastDeepReconcileAt: Int64?
    /// Keyed by the mirror's mailbox id, never the server's (ADR-0033).
    public var mailboxes: [Int64: MailboxSyncMetrics] = [:]

    public init() {}
}

/// Per mailbox, the three questions asked of a sync engine that looks stuck: when did it
/// last work, what went wrong, and when will it try again.
public struct MailboxSyncMetrics: Sendable, Equatable {
    public var lastSuccessAt: Int64?
    public var lastError: String?
    /// Reset to zero by any success. Three marks the mailbox in the UI.
    public var consecutiveFailures = 0
    /// While set, the cadence skips this mailbox even when its interval has elapsed.
    public var nextAttemptAt: Int64?
    public var requests = 0
    public var envelopesWritten = 0
    public var messagesDeleted = 0
    /// Pages the last tail scan walked. One, in the steady state.
    public var lastTailScanPages = 0

    public init() {}
}
