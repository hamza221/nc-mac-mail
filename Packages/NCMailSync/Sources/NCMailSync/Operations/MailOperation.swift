// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A triage action, as the rest of the app asks for it.
///
/// Every `messageIds` here is the **mirror's** id, not the server's (ADR-0033). The drainer
/// reads `remoteId` off the row when it builds the request, which is what lets an action
/// survive a message being re-enumerated under a new server id while it waits in the queue.
///
/// `destinationMailboxId` is likewise a local `mailbox.id`. That is worth saying twice,
/// because `account.archiveMailboxId` and its siblings are the *server's* numbers — see
/// ``OperationQueue/localMailboxId(for:accountId:)``, which is the only correct way to turn
/// one into the other.
public enum MailOperation: Sendable, Equatable {
    /// Absolute state for the keys named, never a toggle: `["seen": true]`.
    ///
    /// The keys are the flag *setter's* spellings — `junk`, `notjunk`, `mdnsent` — and not
    /// the envelope's `$junk`. `api-payloads.md` records the inconsistency; the queue stores
    /// what it will send.
    case setFlags(messageIds: [Int64], flags: [String: Bool])
    case move(messageIds: [Int64], destinationMailboxId: Int64)
    /// To trash, or an erase when the message is already in trash.
    case delete(messageIds: [Int64])
    /// Two operations per message, flags then move, in that order.
    case junk(messageIds: [Int64], junkMailboxId: Int64)
    case moveThread(rootId: String, destinationMailboxId: Int64)
    case deleteThread(rootId: String)
    /// Image trust for one sender, account-wide. Absolute, like the flags: `trusted: false`
    /// is the untrust route, not a toggle.
    case trustSender(email: String, trusted: Bool)
}

/// What one queue row does, which is not quite the same list as ``MailOperation``.
///
/// `junk` is missing because it is flags-then-move and is stored as the two rows it expands
/// into; archive is missing because it was never a kind at all, only a ``move``.
public enum OperationKind: String, Sendable, Codable, CaseIterable {
    case setFlags
    case move
    case delete
    case moveThread
    case deleteThread
    case trustSender

    /// Whether this kind ends the message's life locally, which is what makes it absorb
    /// everything queued before it for the same message.
    var isTerminal: Bool { self == .delete || self == .deleteThread }
}

/// One of the three mailboxes a triage action names by role rather than by id.
public enum SpecialMailbox: Sendable, CaseIterable {
    case archive
    case junk
    case trash
}

/// `pendingOperation.payloadJSON`, decoded.
///
/// `flags` and `destinationMailboxId` are the intent — absolute, so replaying is idempotent
/// and two operations on one field collapse to the later one.
///
/// `before` is the other half, and it is what makes **Discard** honest. `offline-queue.md`
/// promises that discarding reverts the local change to the pre-action state, and nothing
/// else in the row remembers what that was: `baseSyncedAt` says when the server last spoke,
/// not what the flag used to be. The column is free-form text, so this needs no schema
/// change.
struct OperationPayload: Codable, Sendable, Equatable {
    var flags: [String: Bool] = [:]
    /// The server's id for the message the request names — the thread anchor, for a thread
    /// operation.
    ///
    /// Copied in at queue time rather than read from the row at drain time, because the row
    /// may be gone by then: `delete` of a message already in trash erases it locally on the
    /// spot, and without this the drainer would have no id to send and would drop the
    /// operation silently. ADR-0033 says build requests from `remoteId`; this is where the
    /// queue keeps its copy.
    var remoteId: Int64?
    /// Local `mailbox.id`.
    var destinationMailboxId: Int64?
    /// True when the local effect removed the rows rather than moving them, which is the
    /// delete of a message already in trash. Such a discard cannot restore anything.
    var erases = false
    /// The sender a `trustSender` row names, as the user's message spelled it. Optional, like
    /// ``trusted``, so a row written before the kind existed still decodes.
    var senderEmail: String?
    /// `trustSender`'s intent: PUT when true, DELETE when false.
    var trusted: Bool?
    var before = OperationSnapshot()
}

/// The rows an operation touched and what they held first.
struct OperationSnapshot: Codable, Sendable, Equatable {
    /// Local message ids, in the order the effect applied to them.
    var messageIds: [Int64] = []
    /// Previous values for exactly the flag keys the operation sets.
    var flags: [String: Bool] = [:]
    /// Previous `message.mailboxId`, keyed by local message id. A move of ten messages out
    /// of three folders has to put each one back where it came from.
    var mailboxIds: [Int64: Int64] = [:]
    /// Previous `messageBody.isSenderTrusted`, keyed by local message id, for a
    /// `trustSender`. Nil for every other kind.
    var senderTrusted: [Int64: Bool]?
}

extension OperationPayload {
    static func decode(_ json: String) -> OperationPayload {
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(OperationPayload.self, from: data)
        else {
            // A row written by a future version, or by hand. Intent unknown, so the drainer
            // treats it as an empty intent rather than refusing to make progress.
            return OperationPayload()
        }
        return payload
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
