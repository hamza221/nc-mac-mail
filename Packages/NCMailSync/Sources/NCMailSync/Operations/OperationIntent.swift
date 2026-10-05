// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailStore

/// The account settings a `patchAccount` changes. Nil leaves a field alone, which is exactly
/// what `PATCH /api/accounts/{id}` does with a key it does not receive.
///
/// The special-mailbox fields are **local** `mailbox.id`s, like every other mailbox id the
/// queue takes (ADR-0033); the queue resolves them to the server's numbers when it builds the
/// row, because that is what both the request and the account columns hold.
public struct AccountPatch: Codable, Sendable, Equatable {
    public var editorMode: String?
    public var order: Int?
    public var showSubscribedOnly: Bool?
    public var draftsMailboxId: Int64?
    public var sentMailboxId: Int64?
    public var trashMailboxId: Int64?
    public var archiveMailboxId: Int64?
    public var snoozeMailboxId: Int64?
    public var junkMailboxId: Int64?
    public var signatureAboveQuote: Bool?
    public var trashRetentionDays: Int?
    public var searchBody: Bool?
    public var classificationEnabled: Bool?
    public var imipCreate: Bool?

    public init(
        editorMode: String? = nil,
        order: Int? = nil,
        showSubscribedOnly: Bool? = nil,
        draftsMailboxId: Int64? = nil,
        sentMailboxId: Int64? = nil,
        trashMailboxId: Int64? = nil,
        archiveMailboxId: Int64? = nil,
        snoozeMailboxId: Int64? = nil,
        junkMailboxId: Int64? = nil,
        signatureAboveQuote: Bool? = nil,
        trashRetentionDays: Int? = nil,
        searchBody: Bool? = nil,
        classificationEnabled: Bool? = nil,
        imipCreate: Bool? = nil
    ) {
        self.editorMode = editorMode
        self.order = order
        self.showSubscribedOnly = showSubscribedOnly
        self.draftsMailboxId = draftsMailboxId
        self.sentMailboxId = sentMailboxId
        self.trashMailboxId = trashMailboxId
        self.archiveMailboxId = archiveMailboxId
        self.snoozeMailboxId = snoozeMailboxId
        self.junkMailboxId = junkMailboxId
        self.signatureAboveQuote = signatureAboveQuote
        self.trashRetentionDays = trashRetentionDays
        self.searchBody = searchBody
        self.classificationEnabled = classificationEnabled
        self.imipCreate = imipCreate
    }

    /// `later`'s fields where it sets them, this patch's elsewhere: two queued patches are
    /// one request with both changes.
    func merging(_ later: AccountPatch) -> AccountPatch {
        AccountPatch(
            editorMode: later.editorMode ?? editorMode,
            order: later.order ?? order,
            showSubscribedOnly: later.showSubscribedOnly ?? showSubscribedOnly,
            draftsMailboxId: later.draftsMailboxId ?? draftsMailboxId,
            sentMailboxId: later.sentMailboxId ?? sentMailboxId,
            trashMailboxId: later.trashMailboxId ?? trashMailboxId,
            archiveMailboxId: later.archiveMailboxId ?? archiveMailboxId,
            snoozeMailboxId: later.snoozeMailboxId ?? snoozeMailboxId,
            junkMailboxId: later.junkMailboxId ?? junkMailboxId,
            signatureAboveQuote: later.signatureAboveQuote ?? signatureAboveQuote,
            trashRetentionDays: later.trashRetentionDays ?? trashRetentionDays,
            searchBody: later.searchBody ?? searchBody,
            classificationEnabled: later.classificationEnabled ?? classificationEnabled,
            imipCreate: later.imipCreate ?? imipCreate
        )
    }
}

/// One step of a quick action, created when ``stepRemoteId`` is nil and updated otherwise.
///
/// Ids are the server's (ADR-0081), and any of them may be a placeholder from an offline
/// create: the step of an action created a minute ago on a train.
public struct ActionStepIntent: Codable, Sendable, Equatable {
    public var quickActionRemoteId: Int64
    public var stepRemoteId: Int64?
    /// The step's action name as the server spells it: `markAsRead`, `applyTag`,
    /// `moveThread`, …
    public var name: String
    public var order: Int
    public var tagRemoteId: Int64?
    public var mailboxRemoteId: Int64?

    public init(
        quickActionRemoteId: Int64,
        stepRemoteId: Int64? = nil,
        name: String,
        order: Int,
        tagRemoteId: Int64? = nil,
        mailboxRemoteId: Int64? = nil
    ) {
        self.quickActionRemoteId = quickActionRemoteId
        self.stepRemoteId = stepRemoteId
        self.name = name
        self.order = order
        self.tagRemoteId = tagRemoteId
        self.mailboxRemoteId = mailboxRemoteId
    }
}

/// A v2 kind's intent, stored in `payloadJSON`.
///
/// One bag of optionals rather than an enum per kind, because the kind is already the row's
/// `kind` column and because a bag decodes a row written by an older or newer build without
/// failing: a missing key is nil, and the drainer drops an intent it cannot send.
struct OperationIntent: Codable, Sendable, Equatable {
    /// The login a login-scoped row belongs to.
    var loginId: Int64?
    /// The server id the request names: the tag, alias, text block, quick action or mailbox.
    /// Negative for a placeholder (ADR-0081).
    var targetRemoteId: Int64?
    /// A create's placeholder, written over by the server's id when it drains.
    var placeholder: Int64?
    /// The quick action of a step.
    var parentRemoteId: Int64?
    /// Local mailbox id, for the mailbox kinds and the snooze destination.
    var mailboxId: Int64?
    var imapLabel: String?
    var name: String?
    var color: String?
    var title: String?
    var content: String?
    var email: String?
    /// Signature text; nil clears.
    var text: String?
    var key: String?
    var value: String?
    /// Unix seconds, for snooze.
    var until: Int64?
    /// subscribed / syncInBackground / trusted.
    var flag: Bool?
    var type: String?
    var shareWith: String?
    var order: Int?
    var tagRemoteId: Int64?
    var mailboxRemoteId: Int64?
    var attachmentId: String?
    var targetPath: String?
    var accountPatch: AccountPatch?
    /// The account patch's special mailboxes, already resolved to the server's numbers.
    var accountPatchRemote: [String: Int64]?

    /// Later intent wins, field by field, except for the identity fields, which a merge is
    /// only ever between rows that agree on.
    func merging(_ later: OperationIntent) -> OperationIntent {
        var merged = later
        if let earlier = accountPatch, let laterPatch = later.accountPatch {
            merged.accountPatch = earlier.merging(laterPatch)
            merged.accountPatchRemote = (accountPatchRemote ?? [:])
                .merging(later.accountPatchRemote ?? [:]) { _, newer in newer }
        }
        merged.placeholder = placeholder ?? later.placeholder
        return merged
    }
}

/// What a v2 kind's local effect overwrote, so **Discard** can write it back.
///
/// Rows are stored whole (the records are `Codable`) and matched back by server id, never by
/// local id: the settings tables reassign local ids when they are refreshed (ADR-0081).
struct RowSnapshot: Codable, Sendable, Equatable {
    /// False for a create: discarding it deletes the optimistic row.
    var existed = true
    var tag: TagRecord?
    /// Labels each message carried before a tag change.
    var messageTags: [Int64: [String]]?
    var mailbox: MailboxRecord?
    /// Previous `snooze.until` per local message id; a message with no entry was not
    /// snoozed.
    var snoozeUntil: [Int64: Int64]?
    var preferenceKey: String?
    var preferenceValue: String?
    var account: AccountRecord?
    var alias: AliasRecord?
    var textBlock: TextBlockRecord?
    var quickAction: QuickActionRecord?
    var quickActionStep: QuickActionStepRecord?
    /// For the set-membership kinds (share, internal address, trusted domain): whether the
    /// entry was there.
    var present: Bool?
    var shareDisplayName: String?
}
