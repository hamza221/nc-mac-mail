// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// `GET /api/messages/{id}/body`: the parsed message with its attachment list.
///
/// ``body`` is the server's sanitised HTML when ``hasHtmlBody`` is true and
/// plain text otherwise. It is never raw MIME (ADR-0009). The renderer fetches
/// the same fragment again from `.../html?plain=true`; this field is what the
/// store keeps when that call has not run yet.
///
/// `flags` here is an object, the same shape as on the envelope, minus `$junk`
/// and `$notjunk`.
public struct MessageBody: Decodable, Sendable, Hashable, Identifiable {
    /// The payload's `databaseId`.
    public let id: Int
    public let uid: Int?
    public let accountId: Int?
    public let mailboxId: Int?
    public let messageId: String?
    public let subject: String?
    public let dateInt: Int?
    public let flags: MessageFlags

    public let from: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let bcc: [Address]
    public let replyTo: [Address]

    public let hasHtmlBody: Bool
    public let body: String?
    /// Plain-text messages only: the signature the server split off the body.
    public let signature: String?

    public let attachments: [Attachment]
    public let inlineAttachments: [Attachment]

    public let isSenderTrusted: Bool
    public let hasDkimSignature: Bool
    /// Null when the server did not verify, which is the common case: DKIM
    /// checking is a separate call.
    public let dkimValid: Bool?
    public let isPgpMimeEncrypted: Bool
    public let hasAiGeneratedHeader: Bool

    public let unsubscribeUrl: String?
    public let unsubscribeMailto: String?
    public let isOneClickUnsubscribe: Bool
    public let dispositionNotificationTo: String?

    /// Kept as JSON. The store has a column for each and nothing in v1 reads
    /// inside them, so modelling their internals would be guesswork that only
    /// a future feature could check.
    public let smime: AnyJSON?
    public let phishingDetails: AnyJSON?
    public let scheduling: AnyJSON?
    /// Present only when the server has the KItinerary result cached.
    public let itineraries: AnyJSON?

    private enum CodingKeys: String, CodingKey {
        case databaseId
        case uid
        case accountId
        case mailboxId
        case messageId
        case subject
        case dateInt
        case flags
        case from
        case to
        case cc
        case bcc
        case replyTo
        case hasHtmlBody
        case body
        case signature
        case attachments
        case inlineAttachments
        case isSenderTrusted
        case hasDkimSignature
        case dkimValid
        case isPgpMimeEncrypted
        case hasAiGeneratedHeader
        case unsubscribeUrl
        case unsubscribeMailto
        case isOneClickUnsubscribe
        case dispositionNotificationTo
        case smime
        case phishingDetails
        case scheduling
        case itineraries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .databaseId)
        uid = try container.decodeIfPresent(Int.self, forKey: .uid)
        accountId = try container.decodeIfPresent(Int.self, forKey: .accountId)
        mailboxId = try container.decodeIfPresent(Int.self, forKey: .mailboxId)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        dateInt = try container.decodeIfPresent(Int.self, forKey: .dateInt)
        flags = try container.decodeIfPresent(MessageFlags.self, forKey: .flags) ?? MessageFlags()
        from = try container.decodeArray(Address.self, forKey: .from)
        to = try container.decodeArray(Address.self, forKey: .to)
        cc = try container.decodeArray(Address.self, forKey: .cc)
        bcc = try container.decodeArray(Address.self, forKey: .bcc)
        replyTo = try container.decodeArray(Address.self, forKey: .replyTo)
        hasHtmlBody = try container.decodeLenientBool(forKey: .hasHtmlBody)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        attachments = try container.decodeArray(Attachment.self, forKey: .attachments)
        inlineAttachments = try container.decodeArray(Attachment.self, forKey: .inlineAttachments)
        isSenderTrusted = try container.decodeLenientBool(forKey: .isSenderTrusted)
        hasDkimSignature = try container.decodeLenientBool(forKey: .hasDkimSignature)
        dkimValid = try container.decodeIfPresent(Bool.self, forKey: .dkimValid)
        isPgpMimeEncrypted = try container.decodeLenientBool(forKey: .isPgpMimeEncrypted)
        hasAiGeneratedHeader = try container.decodeLenientBool(forKey: .hasAiGeneratedHeader)
        unsubscribeUrl = try container.decodeIfPresent(String.self, forKey: .unsubscribeUrl)
        unsubscribeMailto = try container.decodeIfPresent(String.self, forKey: .unsubscribeMailto)
        isOneClickUnsubscribe = try container.decodeLenientBool(forKey: .isOneClickUnsubscribe)
        dispositionNotificationTo = try container.decodeIfPresent(String.self, forKey: .dispositionNotificationTo)
        smime = try container.decodeIfPresent(AnyJSON.self, forKey: .smime)
        phishingDetails = try container.decodeIfPresent(AnyJSON.self, forKey: .phishingDetails)
        scheduling = try container.decodeIfPresent(AnyJSON.self, forKey: .scheduling)
        itineraries = try container.decodeIfPresent(AnyJSON.self, forKey: .itineraries)
    }
}
