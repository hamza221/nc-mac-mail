// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `draft`. The local row is authoritative (ADR-0066): the composer edits it, and
/// the drafts engine flushes it to `POST/PUT /api/drafts` after the fact. `remoteId` is the
/// server draft once a flush has happened, `savedAt` is when, and `syncError` is why not.
///
/// `id` is nil before insertion; `didInsert` fills it.
public struct DraftRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "draft"

    public var id: Int64?
    public var accountId: Int64
    public var remoteId: Int64?
    /// The local `alias` row to send as, nulled by the schema if the alias disappears.
    public var aliasId: Int64?
    public var subject: String?
    public var bodyPlain: String?
    public var bodyHtml: String?
    /// The editor's own HTML, kept separately so reopening the composer round-trips exactly
    /// what the editor produced rather than what the server echoed back.
    public var editorBody: String?
    public var isHtml: Bool
    public var inReplyToMessageId: String?
    public var smimeSign: Bool
    public var smimeEncrypt: Bool
    public var smimeCertificateRemoteId: Int64?
    public var requestMdn: Bool
    public var isPgpMime: Bool
    public var isAiGenerated: Bool
    public var sendAt: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var savedAt: Int64?
    public var syncError: String?

    public init(
        id: Int64? = nil,
        accountId: Int64,
        remoteId: Int64? = nil,
        aliasId: Int64? = nil,
        subject: String? = nil,
        bodyPlain: String? = nil,
        bodyHtml: String? = nil,
        editorBody: String? = nil,
        isHtml: Bool = true,
        inReplyToMessageId: String? = nil,
        smimeSign: Bool = false,
        smimeEncrypt: Bool = false,
        smimeCertificateRemoteId: Int64? = nil,
        requestMdn: Bool = false,
        isPgpMime: Bool = false,
        isAiGenerated: Bool = false,
        sendAt: Int64? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        savedAt: Int64? = nil,
        syncError: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.aliasId = aliasId
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyHtml = bodyHtml
        self.editorBody = editorBody
        self.isHtml = isHtml
        self.inReplyToMessageId = inReplyToMessageId
        self.smimeSign = smimeSign
        self.smimeEncrypt = smimeEncrypt
        self.smimeCertificateRemoteId = smimeCertificateRemoteId
        self.requestMdn = requestMdn
        self.isPgpMime = isPgpMime
        self.isAiGenerated = isAiGenerated
        self.sendAt = sendAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.savedAt = savedAt
        self.syncError = syncError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `draftRecipient`: one addressee of one draft, in the order the composer shows.
public struct DraftRecipientRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "draftRecipient"

    public var id: Int64?
    public var draftId: Int64
    /// to|cc|bcc, as the send API spells them.
    public var kind: String
    public var position: Int
    public var email: String
    public var label: String?

    public init(
        id: Int64? = nil,
        draftId: Int64,
        kind: String,
        position: Int,
        email: String,
        label: String? = nil
    ) {
        self.id = id
        self.draftId = draftId
        self.kind = kind
        self.position = position
        self.email = email
        self.label = label
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `draftAttachment`.
///
/// `kind` is the web client's attachment type (local upload, forwarded message, one of its
/// attachments, or a Files path); `payloadJSON` keeps verbatim what the send API needs for
/// that kind, and the display columns are extracted so the composer never parses JSON to
/// draw a chip. Staged bytes live at `localPath` on disk, never as a blob — a draft can
/// carry gigabytes.
public struct DraftAttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "draftAttachment"

    public var id: Int64?
    public var draftId: Int64
    public var kind: String
    public var fileName: String
    public var mime: String?
    public var size: Int64?
    public var localPath: String?
    /// The server-side upload id from `POST /api/attachments`, once uploaded.
    public var remoteAttachmentId: Int64?
    public var payloadJSON: String

    public init(
        id: Int64? = nil,
        draftId: Int64,
        kind: String = "local",
        fileName: String,
        mime: String? = nil,
        size: Int64? = nil,
        localPath: String? = nil,
        remoteAttachmentId: Int64? = nil,
        payloadJSON: String = "{}"
    ) {
        self.id = id
        self.draftId = draftId
        self.kind = kind
        self.fileName = fileName
        self.mime = mime
        self.size = size
        self.localPath = localPath
        self.remoteAttachmentId = remoteAttachmentId
        self.payloadJSON = payloadJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `outboxMessage`: a mirror of one `GET /api/outbox` entry. The server owns these
/// rows; the Outbox view observes them and editing one goes back through the draft tables.
///
/// Recipients and attachments stay JSON here because the view only displays them — the
/// normalised child tables belong to `draft`, which is edited field by field.
public struct OutboxMessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "outboxMessage"

    public var id: Int64?
    public var accountId: Int64
    public var remoteId: Int64
    public var aliasRemoteId: Int64?
    public var subject: String?
    public var bodyPlain: String?
    public var bodyHtml: String?
    public var isHtml: Bool
    public var inReplyToMessageId: String?
    public var smimeSign: Bool
    public var smimeEncrypt: Bool
    public var requestMdn: Bool
    public var sendAt: Int64?
    public var failed: Bool
    public var recipientsJSON: String
    public var attachmentsJSON: String
    public var syncedAt: Int64
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        accountId: Int64,
        remoteId: Int64,
        aliasRemoteId: Int64? = nil,
        subject: String? = nil,
        bodyPlain: String? = nil,
        bodyHtml: String? = nil,
        isHtml: Bool = true,
        inReplyToMessageId: String? = nil,
        smimeSign: Bool = false,
        smimeEncrypt: Bool = false,
        requestMdn: Bool = false,
        sendAt: Int64? = nil,
        failed: Bool = false,
        recipientsJSON: String = "[]",
        attachmentsJSON: String = "[]",
        syncedAt: Int64,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.aliasRemoteId = aliasRemoteId
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyHtml = bodyHtml
        self.isHtml = isHtml
        self.inReplyToMessageId = inReplyToMessageId
        self.smimeSign = smimeSign
        self.smimeEncrypt = smimeEncrypt
        self.requestMdn = requestMdn
        self.sendAt = sendAt
        self.failed = failed
        self.recipientsJSON = recipientsJSON
        self.attachmentsJSON = attachmentsJSON
        self.syncedAt = syncedAt
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
