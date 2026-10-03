// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A draft or outbox message — the server's `LocalMessage` entity, which lives
/// in Nextcloud's database rather than on IMAP until a background job flushes it.
///
/// Returned by `POST/PUT /api/drafts`, every `/api/outbox` route, inside the
/// `JSONEnvelope`. Shape verified live (Mail 5.12) by creating a draft.
///
/// `type` is 0 for an outbox message and 1 for a draft
/// (`lib/Db/LocalMessage.php`: `TYPE_OUTGOING`/`TYPE_DRAFT`). `status` is the
/// outbox state machine's step, present since 3.3; both stay raw integers here
/// because the store mirrors them as recorded, not interpreted.
public struct LocalMessage: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let type: Int
    public let accountId: Int
    public let aliasId: Int?
    /// Unix seconds for a scheduled send; nil sends at the next cron run.
    public let sendAt: Int?
    public let updatedAt: Int?
    public let subject: String?
    public let bodyPlain: String?
    public let bodyHtml: String?
    public let editorBody: String?
    public let isHtml: Bool
    public let inReplyToMessageId: String?
    public let attachments: [LocalAttachment]
    public let from: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let bcc: [Address]
    /// True when a send attempt failed and the message needs attention.
    public let failed: Bool
    public let smimeCertificateId: Int?
    public let smimeSign: Bool
    public let smimeEncrypt: Bool
    public let status: Int?
    public let requestMdn: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case accountId
        case aliasId
        case sendAt
        case updatedAt
        case subject
        case bodyPlain
        case bodyHtml
        case editorBody
        case isHtml
        case inReplyToMessageId
        case attachments
        case from
        case to
        case cc
        case bcc
        case failed
        case smimeCertificateId
        case smimeSign
        case smimeEncrypt
        case status
        case requestMdn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decodeIfPresent(Int.self, forKey: .type) ?? 0
        accountId = try container.decode(Int.self, forKey: .accountId)
        aliasId = try container.decodeIfPresent(Int.self, forKey: .aliasId)
        sendAt = try container.decodeIfPresent(Int.self, forKey: .sendAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        bodyPlain = try container.decodeIfPresent(String.self, forKey: .bodyPlain)
        bodyHtml = try container.decodeIfPresent(String.self, forKey: .bodyHtml)
        editorBody = try container.decodeIfPresent(String.self, forKey: .editorBody)
        isHtml = try container.decodeLenientBool(forKey: .isHtml)
        inReplyToMessageId = try container.decodeIfPresent(String.self, forKey: .inReplyToMessageId)
        attachments = try container.decodeArray(LocalAttachment.self, forKey: .attachments)
        from = try container.decodeArray(Address.self, forKey: .from)
        to = try container.decodeArray(Address.self, forKey: .to)
        cc = try container.decodeArray(Address.self, forKey: .cc)
        bcc = try container.decodeArray(Address.self, forKey: .bcc)
        failed = try container.decodeLenientBool(forKey: .failed)
        smimeCertificateId = try container.decodeIfPresent(Int.self, forKey: .smimeCertificateId)
        smimeSign = try container.decodeLenientBool(forKey: .smimeSign)
        smimeEncrypt = try container.decodeLenientBool(forKey: .smimeEncrypt)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        requestMdn = try container.decodeLenientBool(forKey: .requestMdn)
    }
}

/// An uploaded composer attachment — the server's `LocalAttachment` entity.
///
/// `POST /api/attachments` answers this bare, HTTP 201, verified live:
/// `{"id":1,"type":"local","fileName":"…","mimeType":"text/plain","contentId":null,
///   "disposition":"attachment","createdAt":…,"localMessageId":null}`.
/// The same shape appears in `LocalMessage.attachments` once linked. Unlike a
/// mirrored message's `Attachment`, `id` is an integer: it is a database row,
/// not a MIME part path.
public struct LocalAttachment: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let type: String?
    public let fileName: String?
    public let mimeType: String?
    public let contentId: String?
    public let disposition: String?
    public let createdAt: Int?
    public let localMessageId: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case fileName
        case mimeType
        case contentId
        case disposition
        case createdAt
        case localMessageId
    }
}

/// `GET /api/outbox`'s payload inside the `JSONEnvelope`:
/// `{"messages":[…]}`, verified live. `RawBacked` because the store mirrors
/// outbox rows whole (ADR-0020).
public struct OutboxMessages: Decodable, Sendable {
    public let messages: [RawBacked<LocalMessage>]

    private enum CodingKeys: String, CodingKey {
        case messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeArray(RawBacked<LocalMessage>.self, forKey: .messages)
    }
}
