// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// Bodies for the v2 mutation endpoints. Two encoding stances, chosen per route:
//
// - PATCH-style bodies use synthesized encoding, which **omits** nil — the
//   server only changes the keys it receives.
// - "Null means clear" bodies (signature, S/MIME link, out-of-office dates)
//   encode nil as an **explicit JSON null**, because omitting the key would
//   leave the value untouched instead of clearing it.

// MARK: - Accounts

/// `POST /api/accounts` and `PUT /api/accounts/{id}` (PUT ignores
/// `classificationEnabled`; leave it nil there).
public struct AccountRequest: Encodable, Sendable {
    public var accountName: String
    public var emailAddress: String
    public var imapHost: String
    public var imapPort: Int
    public var imapSslMode: String
    public var imapUser: String
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSslMode: String
    public var smtpUser: String
    public var imapPassword: String?
    public var smtpPassword: String?
    /// `password` (default) or `xoauth2`.
    public var authMethod: String?
    public var classificationEnabled: Bool?

    public init(
        accountName: String,
        emailAddress: String,
        imapHost: String,
        imapPort: Int,
        imapSslMode: String,
        imapUser: String,
        smtpHost: String,
        smtpPort: Int,
        smtpSslMode: String,
        smtpUser: String,
        imapPassword: String? = nil,
        smtpPassword: String? = nil,
        authMethod: String? = nil,
        classificationEnabled: Bool? = nil
    ) {
        self.accountName = accountName
        self.emailAddress = emailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSslMode = imapSslMode
        self.imapUser = imapUser
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSslMode = smtpSslMode
        self.smtpUser = smtpUser
        self.imapPassword = imapPassword
        self.smtpPassword = smtpPassword
        self.authMethod = authMethod
        self.classificationEnabled = classificationEnabled
    }
}

/// `PATCH /api/accounts/{id}` — only the keys present are changed, so every
/// field is optional and nil is omitted.
public struct PatchAccountRequest: Encodable, Sendable {
    public var editorMode: String?
    public var order: Int?
    public var showSubscribedOnly: Bool?
    public var draftsMailboxId: Int?
    public var sentMailboxId: Int?
    public var trashMailboxId: Int?
    public var archiveMailboxId: Int?
    public var snoozeMailboxId: Int?
    public var junkMailboxId: Int?
    public var signatureAboveQuote: Bool?
    public var trashRetentionDays: Int?
    public var searchBody: Bool?
    public var classificationEnabled: Bool?
    public var imipCreate: Bool?

    public init(
        editorMode: String? = nil,
        order: Int? = nil,
        showSubscribedOnly: Bool? = nil,
        draftsMailboxId: Int? = nil,
        sentMailboxId: Int? = nil,
        trashMailboxId: Int? = nil,
        archiveMailboxId: Int? = nil,
        snoozeMailboxId: Int? = nil,
        junkMailboxId: Int? = nil,
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
}

/// `PUT /api/accounts/{id}/signature` and `…/aliases/{id}/signature`.
/// Nil clears, so it is sent as an explicit null.
public struct SignatureRequest: Encodable, Sendable {
    public var signature: String?

    public init(signature: String?) {
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case signature
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signature, forKey: .signature)
    }
}

/// `PUT /api/accounts/{id}/smime-certificate`. Nil unlinks → explicit null.
public struct SmimeCertificateLinkRequest: Encodable, Sendable {
    public var smimeCertificateId: Int?

    public init(smimeCertificateId: Int?) {
        self.smimeCertificateId = smimeCertificateId
    }

    private enum CodingKeys: String, CodingKey {
        case smimeCertificateId
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(smimeCertificateId, forKey: .smimeCertificateId)
    }
}

/// `POST`/`PUT /api/accounts/{accountId}/aliases`. The display name's key is
/// `aliasName` here even though the response calls it `name`.
public struct AliasRequest: Encodable, Sendable {
    public var alias: String
    public var aliasName: String
    public var smimeCertificateId: Int?

    public init(alias: String, aliasName: String, smimeCertificateId: Int? = nil) {
        self.alias = alias
        self.aliasName = aliasName
        self.smimeCertificateId = smimeCertificateId
    }
}

/// `POST /api/delegations/{accountId}`.
public struct DelegationRequest: Encodable, Sendable {
    public var userId: String

    public init(userId: String) {
        self.userId = userId
    }
}

/// `POST /api/oauth/state`.
public struct OAuthStateRequest: Encodable, Sendable {
    public var accountId: Int

    public init(accountId: Int) {
        self.accountId = accountId
    }
}

// MARK: - Mailboxes

/// `POST /api/mailboxes`. Subfolders spell the delimiter into `name`.
public struct CreateMailboxRequest: Encodable, Sendable {
    public var accountId: Int
    public var name: String

    public init(accountId: Int, name: String) {
        self.accountId = accountId
        self.name = name
    }
}

/// `PATCH /api/mailboxes/{id}` — nil is omitted, like the account PATCH.
public struct PatchMailboxRequest: Encodable, Sendable {
    public var name: String?
    public var subscribed: Bool?
    public var syncInBackground: Bool?

    public init(name: String? = nil, subscribed: Bool? = nil, syncInBackground: Bool? = nil) {
        self.name = name
        self.subscribed = subscribed
        self.syncInBackground = syncInBackground
    }
}

// MARK: - Messages and threads

/// `POST /api/messages/{id}/snooze` and `POST /api/thread/{id}/snooze`.
public struct SnoozeRequest: Encodable, Sendable {
    /// When the message resurfaces, unix seconds.
    public var unixTimestamp: Int
    /// The account's snooze mailbox.
    public var destMailboxId: Int

    public init(unixTimestamp: Int, destMailboxId: Int) {
        self.unixTimestamp = unixTimestamp
        self.destMailboxId = destMailboxId
    }
}

/// `POST /api/messages/{id}/attachment/{attachmentId}` and
/// `POST /api/messages/{id}/file` — where in Files to save.
public struct TargetPathRequest: Encodable, Sendable {
    public var targetPath: String

    public init(targetPath: String) {
        self.targetPath = targetPath
    }
}

// MARK: - Drafts and outbox

/// One recipient in a compose body: `{"label": …, "email": …}`.
public struct RecipientRequest: Encodable, Sendable {
    public var label: String?
    public var email: String

    public init(label: String? = nil, email: String) {
        self.label = label
        self.email = email
    }
}

/// `POST/PUT /api/drafts` and `POST/PUT /api/outbox` share one parameter list
/// (`draftId` only on create; `failed` only on update — leave the others nil).
///
/// `attachments` stays `AnyJSON`: the entries are the `LocalAttachment` records
/// the upload route returned, echoed back whole, and WS-23 owns their exact
/// round-trip.
public struct ComposeMessageRequest: Encodable, Sendable {
    public var accountId: Int
    public var subject: String
    public var bodyPlain: String?
    public var bodyHtml: String?
    public var editorBody: String?
    public var isHtml: Bool
    public var smimeSign: Bool
    public var smimeEncrypt: Bool
    public var to: [RecipientRequest]
    public var cc: [RecipientRequest]
    public var bcc: [RecipientRequest]
    public var attachments: [AnyJSON]
    public var aliasId: Int?
    public var inReplyToMessageId: String?
    public var smimeCertificateId: Int?
    public var sendAt: Int?
    public var draftId: Int?
    public var requestMdn: Bool
    public var isPgpMime: Bool
    public var failed: Bool?

    public init(
        accountId: Int,
        subject: String,
        bodyPlain: String? = nil,
        bodyHtml: String? = nil,
        editorBody: String? = nil,
        isHtml: Bool = true,
        smimeSign: Bool = false,
        smimeEncrypt: Bool = false,
        to: [RecipientRequest] = [],
        cc: [RecipientRequest] = [],
        bcc: [RecipientRequest] = [],
        attachments: [AnyJSON] = [],
        aliasId: Int? = nil,
        inReplyToMessageId: String? = nil,
        smimeCertificateId: Int? = nil,
        sendAt: Int? = nil,
        draftId: Int? = nil,
        requestMdn: Bool = false,
        isPgpMime: Bool = false,
        failed: Bool? = nil
    ) {
        self.accountId = accountId
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyHtml = bodyHtml
        self.editorBody = editorBody
        self.isHtml = isHtml
        self.smimeSign = smimeSign
        self.smimeEncrypt = smimeEncrypt
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.attachments = attachments
        self.aliasId = aliasId
        self.inReplyToMessageId = inReplyToMessageId
        self.smimeCertificateId = smimeCertificateId
        self.sendAt = sendAt
        self.draftId = draftId
        self.requestMdn = requestMdn
        self.isPgpMime = isPgpMime
        self.failed = failed
    }
}

/// `POST /api/outbox/from-draft/{id}`.
public struct SendAtRequest: Encodable, Sendable {
    public var sendAt: Int

    public init(sendAt: Int) {
        self.sendAt = sendAt
    }
}

// MARK: - Tags

/// `POST /api/tags` and `PUT /api/tags/{id}`.
public struct TagRequest: Encodable, Sendable {
    public var displayName: String
    /// A CSS colour, `#rrggbb`.
    public var color: String

    public init(displayName: String, color: String) {
        self.displayName = displayName
        self.color = color
    }
}

// MARK: - Preferences and contacts

/// `PUT /api/preferences/{key}` — the key is in the path *and* the body.
public struct PreferenceRequest: Encodable, Sendable {
    public var key: String
    public var value: AnyJSON

    public init(key: String, value: AnyJSON) {
        self.key = key
        self.value = value
    }
}

/// `PUT /api/contactIntegration/add`.
public struct ContactAddRequest: Encodable, Sendable {
    public var uid: String
    public var mail: String

    public init(uid: String, mail: String) {
        self.uid = uid
        self.mail = mail
    }
}

/// `PUT /api/contactIntegration/new`.
public struct ContactNewRequest: Encodable, Sendable {
    public var contactName: String
    public var mail: String

    public init(contactName: String, mail: String) {
        self.contactName = contactName
        self.mail = mail
    }
}

// MARK: - Sieve, filters, out of office, follow-up

/// `PUT /api/sieve/account/{id}`.
public struct SieveAccountRequest: Encodable, Sendable {
    public var sieveEnabled: Bool
    public var sieveHost: String
    public var sievePort: Int
    public var sieveUser: String
    public var sievePassword: String
    public var sieveSslMode: String

    public init(
        sieveEnabled: Bool,
        sieveHost: String,
        sievePort: Int,
        sieveUser: String,
        sievePassword: String,
        sieveSslMode: String
    ) {
        self.sieveEnabled = sieveEnabled
        self.sieveHost = sieveHost
        self.sievePort = sievePort
        self.sieveUser = sieveUser
        self.sievePassword = sievePassword
        self.sieveSslMode = sieveSslMode
    }
}

/// `PUT /api/sieve/active/{id}`.
public struct SieveScriptRequest: Encodable, Sendable {
    public var script: String

    public init(script: String) {
        self.script = script
    }
}

/// `PUT /api/filter/{accountId}` — the filters round-trip as recorded, so the
/// list is `AnyJSON` rather than a re-modelled copy that could drop a key.
public struct FiltersRequest: Encodable, Sendable {
    public var filters: [AnyJSON]

    public init(filters: [AnyJSON]) {
        self.filters = filters
    }
}

/// `POST /api/out-of-office/{accountId}`. The dates are nullable ISO strings
/// and nil means "no bound", which the server needs to see as an explicit null.
public struct OutOfOfficeRequest: Encodable, Sendable {
    public var enabled: Bool
    public var start: String?
    public var end: String?
    public var subject: String
    public var message: String

    public init(enabled: Bool, start: String?, end: String?, subject: String, message: String) {
        self.enabled = enabled
        self.start = start
        self.end = end
        self.subject = subject
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case start
        case end
        case subject
        case message
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(subject, forKey: .subject)
        try container.encode(message, forKey: .message)
    }
}

/// `POST /api/follow-up/check-message-ids`.
public struct FollowUpCheckRequest: Encodable, Sendable {
    public var messageIds: [Int]

    public init(messageIds: [Int]) {
        self.messageIds = messageIds
    }
}

// MARK: - Quick actions

/// `POST /api/quick-actions` and `PUT /api/quick-actions/{id}` (rename sends
/// only `name`; leave `accountId` nil).
public struct QuickActionRequest: Encodable, Sendable {
    public var name: String
    public var accountId: Int?

    public init(name: String, accountId: Int? = nil) {
        self.name = name
        self.accountId = accountId
    }
}

/// `POST /api/action-step` and `PUT /api/action-step/{id}`.
public struct ActionStepRequest: Encodable, Sendable {
    /// One of the server's step kinds, e.g. `markAsRead`, `applyTag`.
    public var name: String
    public var order: Int
    /// The owning quick action — only on create.
    public var actionId: Int?
    public var tagId: Int?
    public var mailboxId: Int?

    public init(name: String, order: Int, actionId: Int? = nil, tagId: Int? = nil, mailboxId: Int? = nil) {
        self.name = name
        self.order = order
        self.actionId = actionId
        self.tagId = tagId
        self.mailboxId = mailboxId
    }
}

// MARK: - Text blocks

/// `POST /api/textBlocks` and `PUT /api/textBlocks/{id}`.
public struct TextBlockRequest: Encodable, Sendable {
    public var title: String
    public var content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

/// `POST /api/textBlockshares`.
public struct TextBlockShareRequest: Encodable, Sendable {
    public var textBlockId: Int
    public var shareWith: String
    /// `user` or `group`.
    public var type: String

    public init(textBlockId: Int, shareWith: String, type: String) {
        self.textBlockId = textBlockId
        self.shareWith = shareWith
        self.type = type
    }
}

// MARK: - Non-Mail OCS

/// `POST /ocs/v2.php/translation/translate`. A nil `fromLanguage` asks the
/// server to detect, and is sent as an explicit null.
public struct TranslateRequest: Encodable, Sendable {
    public var text: String
    public var fromLanguage: String?
    public var toLanguage: String

    public init(text: String, fromLanguage: String? = nil, toLanguage: String) {
        self.text = text
        self.fromLanguage = fromLanguage
        self.toLanguage = toLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fromLanguage
        case toLanguage
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(fromLanguage, forKey: .fromLanguage)
        try container.encode(toLanguage, forKey: .toLanguage)
    }
}

/// `POST /ocs/v2.php/apps/files_sharing/api/v1/shares` — a public link share.
public struct ShareLinkRequest: Encodable, Sendable {
    public var path: String
    /// 3 is "public link" in the OCS share API.
    public var shareType: Int

    public init(path: String, shareType: Int = 3) {
        self.path = path
        self.shareType = shareType
    }
}
