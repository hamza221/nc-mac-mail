// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A whole row of `message`.
///
/// Read this when you need the envelope in full. The message list does not: it reads
/// ``MessageRow``, which is a third of the columns and the reason a 50,000-row mailbox
/// scrolls.
public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "message"

    public var id: Int64
    public var mailboxId: Int64
    public var accountId: Int64
    public var uid: Int64?
    public var messageId: String?
    public var threadRootId: String?
    public var inReplyTo: String?
    public var referencesJSON: String?
    public var subject: String?
    public var previewText: String?
    public var summary: String?
    public var sentAt: Int64
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var isDeleted: Bool
    public var isDraft: Bool
    public var isForwarded: Bool
    public var isImportant: Bool
    public var isJunk: Bool
    public var isNotJunk: Bool
    public var isMdnSent: Bool
    public var hasAttachments: Bool
    public var mentionsMe: Bool
    public var isEncrypted: Bool
    public var isImipMessage: Bool
    public var fromEmail: String?
    public var fromLabel: String?
    public var syncedAt: Int64
    public var bodyState: BodyState
    public var rawJSON: String
}

/// The flags a stored envelope carries, one property per column.
///
/// A struct rather than fourteen parameters, because a positional list of fourteen booleans is
/// a bug waiting for a tired reviewer. Not the same type as `NCMailCore.MessageFlags`
/// ([ADR-0021](../../../../docs/decisions/0021-one-message-flags-type.md)): that one is decoded
/// from the wire and names its properties after the IMAP flags, this one names them after the
/// columns. `NCMailSync` maps between them, and the names differ so that a module importing
/// both is not ambiguous. See ADR-0023.
public struct MessageFlags: Codable, Sendable, Equatable {
    public var isSeen = false
    public var isFlagged = false
    public var isAnswered = false
    public var isDeleted = false
    public var isDraft = false
    public var isForwarded = false
    public var isImportant = false
    public var isJunk = false
    public var isNotJunk = false
    public var isMdnSent = false
    public var hasAttachments = false
    public var mentionsMe = false
    public var isEncrypted = false
    public var isImipMessage = false

    public init() {}
}

/// One address on a message, in the order the header listed it.
public struct EnvelopeAddress: Sendable, Equatable {
    public var kind: AddressKind
    public var email: String
    public var label: String?

    public init(kind: AddressKind, email: String, label: String? = nil) {
        self.kind = kind
        self.email = email
        self.label = label
    }
}

/// An envelope as the sync engine has it, ready to be written.
///
/// `bodyState` is not here. An envelope arriving again — a flag changed, a deep reconcile —
/// must not tell the mirror it has lost a body it already downloaded, and the only way to
/// make that impossible is for the write not to mention the column. See ADR-0023.
///
/// `Encodable` and not `Codable`: `addresses` is not a column, it goes to `messageAddress`,
/// and leaving it out of `CodingKeys` is what keeps the generated INSERT honest.
public struct EnvelopeWrite: Encodable, PersistableRecord, Sendable {
    public static let databaseTableName = "message"

    public var id: Int64
    public var mailboxId: Int64
    public var accountId: Int64
    public var uid: Int64?
    public var messageId: String?
    public var threadRootId: String?
    public var inReplyTo: String?
    public var referencesJSON: String?
    public var subject: String?
    public var previewText: String?
    public var summary: String?
    public var sentAt: Int64
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var isDeleted: Bool
    public var isDraft: Bool
    public var isForwarded: Bool
    public var isImportant: Bool
    public var isJunk: Bool
    public var isNotJunk: Bool
    public var isMdnSent: Bool
    public var hasAttachments: Bool
    public var mentionsMe: Bool
    public var isEncrypted: Bool
    public var isImipMessage: Bool
    public var fromEmail: String?
    public var fromLabel: String?
    public var syncedAt: Int64
    public var rawJSON: String

    /// Written to `messageAddress`, and flattened into the `people` column of the search index.
    public var addresses: [EnvelopeAddress]

    enum CodingKeys: String, CodingKey {
        case id, mailboxId, accountId, uid, messageId, threadRootId, inReplyTo, referencesJSON
        case subject, previewText, summary, sentAt
        case isSeen, isFlagged, isAnswered, isDeleted, isDraft, isForwarded, isImportant
        case isJunk, isNotJunk, isMdnSent, hasAttachments, mentionsMe, isEncrypted, isImipMessage
        case fromEmail, fromLabel, syncedAt, rawJSON
    }

    public init(
        id: Int64,
        mailboxId: Int64,
        accountId: Int64,
        sentAt: Int64,
        syncedAt: Int64,
        uid: Int64? = nil,
        messageId: String? = nil,
        threadRootId: String? = nil,
        inReplyTo: String? = nil,
        referencesJSON: String? = nil,
        subject: String? = nil,
        previewText: String? = nil,
        summary: String? = nil,
        flags: MessageFlags = MessageFlags(),
        fromEmail: String? = nil,
        fromLabel: String? = nil,
        addresses: [EnvelopeAddress] = [],
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.mailboxId = mailboxId
        self.accountId = accountId
        self.uid = uid
        self.messageId = messageId
        self.threadRootId = threadRootId
        self.inReplyTo = inReplyTo
        self.referencesJSON = referencesJSON
        self.subject = subject
        self.previewText = previewText
        self.summary = summary
        self.sentAt = sentAt
        isSeen = flags.isSeen
        isFlagged = flags.isFlagged
        isAnswered = flags.isAnswered
        isDeleted = flags.isDeleted
        isDraft = flags.isDraft
        isForwarded = flags.isForwarded
        isImportant = flags.isImportant
        isJunk = flags.isJunk
        isNotJunk = flags.isNotJunk
        isMdnSent = flags.isMdnSent
        hasAttachments = flags.hasAttachments
        mentionsMe = flags.mentionsMe
        isEncrypted = flags.isEncrypted
        isImipMessage = flags.isImipMessage
        self.fromEmail = fromEmail
        self.fromLabel = fromLabel
        self.syncedAt = syncedAt
        self.rawJSON = rawJSON
        self.addresses = addresses
    }

    /// `"Name <addr>"` for from, to and cc, space joined — the `people` column of the index.
    ///
    /// Bcc is left out deliberately: on a received message it is either empty or someone
    /// else's disclosure, and indexing it would make it searchable text.
    var indexedPeople: String {
        addresses
            .filter { $0.kind == .from || $0.kind == .to || $0.kind == .cc }
            .map { address in
                guard let label = address.label, !label.isEmpty else { return address.email }
                return "\(label) <\(address.email)>"
            }
            .joined(separator: " ")
    }
}

/// A row of `messageAddress`.
public struct MessageAddressRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "messageAddress"

    public var messageId: Int64
    public var kind: AddressKind
    public var position: Int
    public var email: String
    public var label: String?

    public init(messageId: Int64, kind: AddressKind, position: Int, email: String, label: String? = nil) {
        self.messageId = messageId
        self.kind = kind
        self.position = position
        self.email = email
        self.label = label
    }
}
