// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A message as the list and sync endpoints report it: headers, flags and a
/// preview, but no body.
public struct Envelope: Decodable, Sendable, Hashable, Identifiable {
    /// The payload's `databaseId`, which is what every other endpoint takes.
    public let id: Int
    /// The IMAP uid inside its mailbox. Unique per mailbox, not globally.
    public let uid: Int?
    public let remoteId: String?
    public let mailboxId: Int
    public let subject: String?
    /// Unix seconds, and also the pagination cursor for `GET /api/messages`.
    public let dateInt: Int
    public let flags: MessageFlags
    /// Keyed by IMAP label. An envelope with no tags arrives as `[]`.
    public let tags: [String: Tag]
    public let from: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let bcc: [Address]
    public let messageId: String?
    public let inReplyTo: String?
    /// Null or an array, never a string.
    public let references: [String]
    public let threadRootId: String?
    public let previewText: String?
    public let summary: String?
    public let encrypted: Bool
    public let imipMessage: Bool
    /// Reported as `0`/`1`, not as a boolean.
    public let mentionsMe: Bool
    public let avatar: Avatar?
    public let fetchAvatarFromClient: Bool
    public let attachments: [Attachment]

    /// The sender avatar the server resolved, from the address book, Gravatar
    /// or the sender domain's favicon.
    public struct Avatar: Decodable, Sendable, Hashable {
        /// True when the URL points off the Nextcloud instance, which means
        /// fetching it leaks the user's IP to a third party.
        public let isExternal: Bool
        public let mime: String?
        public let url: String?

        private enum CodingKeys: String, CodingKey {
            case isExternal
            case mime
            case url
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isExternal = try container.decodeLenientBool(forKey: .isExternal)
            mime = try container.decodeIfPresent(String.self, forKey: .mime)
            url = try container.decodeIfPresent(String.self, forKey: .url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case databaseId
        case uid
        case remoteId
        case mailboxId
        case subject
        case dateInt
        case flags
        case tags
        case from
        case to
        case cc
        case bcc
        case messageId
        case inReplyTo
        case references
        case threadRootId
        case previewText
        case summary
        case encrypted
        case imipMessage
        case mentionsMe
        case avatar
        case fetchAvatarFromClient
        case attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .databaseId)
        uid = try container.decodeIfPresent(Int.self, forKey: .uid)
        remoteId = try container.decodeIfPresent(String.self, forKey: .remoteId)
        mailboxId = try container.decode(Int.self, forKey: .mailboxId)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        dateInt = try container.decode(Int.self, forKey: .dateInt)
        flags = try container.decodeIfPresent(MessageFlags.self, forKey: .flags) ?? MessageFlags()
        tags = try container.decodePHPDictionary(Tag.self, forKey: .tags)
        from = try container.decodeArray(Address.self, forKey: .from)
        to = try container.decodeArray(Address.self, forKey: .to)
        cc = try container.decodeArray(Address.self, forKey: .cc)
        bcc = try container.decodeArray(Address.self, forKey: .bcc)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try container.decodeArray(String.self, forKey: .references)
        threadRootId = try container.decodeIfPresent(String.self, forKey: .threadRootId)
        previewText = try container.decodeIfPresent(String.self, forKey: .previewText)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        encrypted = try container.decodeLenientBool(forKey: .encrypted)
        imipMessage = try container.decodeLenientBool(forKey: .imipMessage)
        mentionsMe = try container.decodeLenientBool(forKey: .mentionsMe)
        avatar = try container.decodeIfPresent(Avatar.self, forKey: .avatar)
        fetchAvatarFromClient = try container.decodeLenientBool(forKey: .fetchAvatarFromClient)
        attachments = try container.decodeArray(Attachment.self, forKey: .attachments)
    }

    /// The first sender, which is what the list row and the store's
    /// denormalised `fromEmail`/`fromLabel` columns hold.
    public var sender: Address? { from.first }
}
