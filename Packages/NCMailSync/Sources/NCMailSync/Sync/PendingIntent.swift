// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import NCMailStore

/// A change the user has made that the server has not been told about yet.
///
/// `offline-queue.md` stores intent rather than a diff — `{"seen": true}`, never
/// `{"toggle": "seen"}` — for three reasons, and this type is the third of them: the
/// conflict rule "local wins for the fields the operation sets" needs something concrete to
/// name, and these are the fields.
///
/// The flag keys are the ones `SetFlagsRequest` uses, which are the *setter's* spellings and
/// not the envelope's: `junk`, not `$junk`. That is upstream's inconsistency and it is
/// recorded in `api-payloads.md`; the queue stores what it will send.
public struct PendingIntent: Sendable, Equatable {
    /// The mirror's message id, not the server's (ADR-0033). The queue rows carry the local
    /// id because the message may be gone from the server by the time the drain runs.
    public var messageId: Int64
    /// Absolute desired state of the flags this operation sets.
    public var flags: [String: Bool]

    public init(messageId: Int64, flags: [String: Bool]) {
        self.messageId = messageId
        self.flags = flags
    }
}

/// What the sync engine needs from WS-06's queue.
///
/// Two questions, both of which only the drainer can answer: *send everything you are
/// holding*, and *which fields are you holding?* The first is the ordering rule in
/// `sync-engine.md` — drain, then sync, then backfill — and the second is the conflict rule.
///
/// A protocol rather than the concrete `OperationDrainer` because WS-06 lands after WS-05
/// and the ordering rule has to ship whether or not the drainer exists yet: a nil drainer is
/// an account with an empty queue, which is the common case anyway. It is also spelled
/// `OperationDraining` rather than `OperationDrainer` so that WS-06's actor can take the
/// obvious name inside the same module.
public protocol OperationDraining: Sendable {
    /// Sends every operation that is ready, in `id` order, one at a time. Returns when the
    /// queue is empty or nothing more can be sent — offline, or everything left is waiting
    /// out a backoff.
    func drain() async

    /// The fields a not-yet-sent operation owns, so a sync does not overwrite them.
    ///
    /// Empty is the answer that matters: once the queue is drained there is no conflict to
    /// resolve at all, and `sync-engine.md` is explicit that this is why the drain runs
    /// first.
    func pendingIntents() async -> [PendingIntent]
}

/// Applies the conflict table from `sync-engine.md#conflict-rules-in-one-place` to one page
/// of envelopes.
///
/// Only the flags are masked, and that is deliberate rather than an omission:
///
/// | Situation | Winner |
/// | --- | --- |
/// | No pending operation | Server, always |
/// | A pending operation sets field X | Local for X, server for everything else |
/// | Vanished server-side, operation pending | Server — the message is gone |
/// | Moved server-side, local move queued | Server, after the drain resolves |
/// | Envelope differs, body already stored | Keep the body |
///
/// The last row needs no code here because `EnvelopeWrite` has no `bodyState` column
/// (ADR-0023), so no sync response can tell the mirror it has lost a body. The move row is
/// the one that looks like a gap and is not: the table says do not guess a position, let the
/// drain fail against the server and reconcile.
enum SyncConflicts {
    /// - Parameters:
    ///   - writes: the page as the server described it.
    ///   - localIds: the mirror's id for each write, in the same order. A write carries the
    ///     server's id, and the queue is keyed by the local one.
    ///   - intents: what the queue is holding, keyed by local message id.
    /// - Returns: the page with each queued field restored to the user's intent.
    static func apply(
        _ writes: [EnvelopeWrite],
        localIds: [Int64?],
        intents: [Int64: PendingIntent]
    ) -> [EnvelopeWrite] {
        guard !intents.isEmpty else { return writes }
        return writes.enumerated().map { index, write in
            guard
                index < localIds.count,
                let localId = localIds[index],
                let intent = intents[localId]
            else { return write }
            return apply(intent, to: write)
        }
    }

    static func apply(_ intent: PendingIntent, to write: EnvelopeWrite) -> EnvelopeWrite {
        var masked = write
        for (key, value) in intent.flags {
            switch key {
            case "seen": masked.isSeen = value
            case "flagged": masked.isFlagged = value
            case "answered": masked.isAnswered = value
            case "deleted": masked.isDeleted = value
            case "draft": masked.isDraft = value
            case "forwarded": masked.isForwarded = value
            case "important": masked.isImportant = value
            case "junk": masked.isJunk = value
            case "notjunk": masked.isNotJunk = value
            case "mdnsent": masked.isMdnSent = value
            default:
                // A key the store has no column for. The queue may legitimately hold one —
                // the flag setter accepts any IMAP keyword — and it is not this layer's
                // business to reject it.
                continue
            }
        }
        return masked
    }
}
