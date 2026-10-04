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

    // MARK: v2 — tags (ADR-0081: settings rows are named by server id)

    /// The label is the IMAP keyword (`$label1`), which is what the route takes.
    case setTag(messageIds: [Int64], imapLabel: String)
    case unsetTag(messageIds: [Int64], imapLabel: String)
    case createTag(displayName: String, color: String)
    /// `tagRemoteId` may be a placeholder from an offline ``createTag(displayName:color:)``.
    case updateTag(tagRemoteId: Int64, displayName: String, color: String)
    case deleteTag(tagRemoteId: Int64)

    // MARK: v2 — snooze

    /// Unix seconds. Moves the messages into the account's snooze mailbox.
    case snooze(messageIds: [Int64], until: Int64)
    case unsnooze(messageIds: [Int64])
    case snoozeThread(rootId: String, until: Int64)
    case unsnoozeThread(rootId: String)

    // MARK: v2 — mailboxes (local `mailbox.id`, as v1)

    /// `name` is the full path, delimiter included, as the server names mailboxes.
    case createMailbox(name: String)
    case renameMailbox(mailboxId: Int64, name: String)
    /// A rename to the leaf under `parentMailboxId`'s path; nil moves it to the top level.
    case moveMailbox(mailboxId: Int64, parentMailboxId: Int64?)
    case deleteMailbox(mailboxId: Int64)
    case setMailboxSubscribed(mailboxId: Int64, subscribed: Bool)
    case setMailboxSyncInBackground(mailboxId: Int64, enabled: Bool)
    case clearMailbox(mailboxId: Int64)
    case markMailboxRead(mailboxId: Int64)

    // MARK: v2 — settings

    /// Login-scoped. The value is stored and sent as a string, which is what every
    /// preference the web client writes is.
    case setPreference(key: String, value: String)
    case patchAccount(AccountPatch)
    /// Nil clears.
    case setSignature(String?)
    case createAlias(email: String, name: String)
    case updateAlias(aliasRemoteId: Int64, email: String, name: String)
    case deleteAlias(aliasRemoteId: Int64)
    case setAliasSignature(aliasRemoteId: Int64, signature: String?)

    // MARK: v2 — text blocks (login-scoped)

    case createTextBlock(title: String, content: String)
    case updateTextBlock(textBlockRemoteId: Int64, title: String, content: String)
    case deleteTextBlock(textBlockRemoteId: Int64)
    /// `type` is the server's share type: `user` or `group`.
    case shareTextBlock(textBlockRemoteId: Int64, shareWith: String, type: String)
    case unshareTextBlock(textBlockRemoteId: Int64, shareWith: String)

    // MARK: v2 — quick actions

    case createQuickAction(name: String)
    case updateQuickAction(quickActionRemoteId: Int64, name: String)
    case deleteQuickAction(quickActionRemoteId: Int64)
    case upsertActionStep(ActionStepIntent)
    case deleteActionStep(quickActionRemoteId: Int64, stepRemoteId: Int64)

    // MARK: v2 — addresses (login-scoped)

    /// `type` is `individual` or `domain`.
    case addInternalAddress(address: String, type: String)
    case removeInternalAddress(address: String, type: String)
    case trustDomain(domain: String, trusted: Bool)

    // MARK: v2 — mail actions

    case sendMDN(messageId: Int64)
    case unsubscribe(messageId: Int64)
    /// The whole message as `.eml` when `attachmentId` is nil.
    case saveToFiles(messageId: Int64, attachmentId: String?, targetPath: String)

    // MARK: v2 — contacts and calendars, executed by `DAVWriteHandling`

    case contactPut(DAVWritePayload)
    case contactDelete(DAVWritePayload)
    case addressBookCreate(DAVWritePayload)
    case addressBookUpdate(DAVWritePayload)
    case addressBookDelete(DAVWritePayload)
    case addressBookShare(DAVWritePayload)
    case calendarPut(DAVWritePayload)
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

    case setTag
    case unsetTag
    case createTag
    case updateTag
    case deleteTag
    case snooze
    case unsnooze
    case snoozeThread
    case unsnoozeThread
    case createMailbox
    case renameMailbox
    case moveMailbox
    case deleteMailbox
    case setMailboxSubscribed
    case setMailboxSyncInBackground
    case clearMailbox
    case markMailboxRead
    case setPreference
    case patchAccount
    case setSignature
    case createAlias
    case updateAlias
    case deleteAlias
    case setAliasSignature
    case createTextBlock
    case updateTextBlock
    case deleteTextBlock
    case shareTextBlock
    case unshareTextBlock
    case createQuickAction
    case updateQuickAction
    case deleteQuickAction
    case upsertActionStep
    case deleteActionStep
    case addInternalAddress
    case removeInternalAddress
    case trustDomain
    case sendMDN
    case unsubscribe
    case saveToFiles
    case contactPut
    case contactDelete
    case addressBookCreate
    case addressBookUpdate
    case addressBookDelete
    case addressBookShare
    case calendarPut

    /// Whether this kind ends its subject's life, which is what makes it absorb everything
    /// queued before it for the same subject.
    var isTerminal: Bool {
        switch self {
        case .delete, .deleteThread, .deleteTag, .deleteMailbox, .deleteAlias, .deleteTextBlock,
            .deleteQuickAction, .deleteActionStep, .contactDelete, .addressBookDelete:
            true
        default:
            false
        }
    }

    /// Kinds whose intent is absolute state of one subject, so two in a row are one request.
    var mergesWithItself: Bool {
        switch self {
        case .setFlags, .move, .moveThread, .trustSender, .updateTag, .renameMailbox, .moveMailbox,
            .setMailboxSubscribed, .setMailboxSyncInBackground, .setPreference, .patchAccount,
            .setSignature, .updateAlias, .setAliasSignature, .updateTextBlock, .updateQuickAction,
            .upsertActionStep, .trustDomain, .contactPut, .addressBookUpdate, .calendarPut:
            true
        default:
            false
        }
    }

    /// Executed by ``DAVWriteHandling`` rather than through `MailClient`.
    public var isDAV: Bool {
        switch self {
        case .contactPut, .contactDelete, .addressBookCreate, .addressBookUpdate, .addressBookDelete,
            .addressBookShare, .calendarPut:
            true
        default:
            false
        }
    }
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
    /// A v2 settings/mailbox/tag/snooze kind's intent. Optional so a v1 row still decodes.
    var intent: OperationIntent?
    /// A DAV kind's intent and `before`, which ``DAVWriteHandling`` applies and reverts.
    var dav: DAVWritePayload?
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
    /// What a v2 kind's row effects overwrote. Nil for v1 kinds and for kinds with no
    /// local effect.
    var rows: RowSnapshot?
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
