// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// One IMAP folder as `GET /api/mailboxes` reports it.
///
/// The payload's `id` field is `base64_encode(name)` and is not an id. This
/// model does not carry it: `databaseId` is the numeric key every other
/// endpoint wants, so it is decoded as `id` and the base64 string is dropped.
public struct Mailbox: Decodable, Sendable, Hashable, Identifiable {
    /// The payload's `databaseId`.
    public let id: Int
    public let accountId: Int
    /// The full IMAP path, for example `INBOX.Work`. Split it on ``delimiter``
    /// to get the leaf; `displayName` will not do it for you.
    public let name: String
    /// The server sends the full path here too, not the leaf. Kept because it
    /// is what the web client shows, and because the two can differ on servers
    /// with a personal namespace.
    public let displayName: String
    /// IMAP attributes, server-cased. Compare case-insensitively.
    public let attributes: [String]
    public let delimiter: String
    public let specialUse: [String]
    /// `specialUse[0]` or nil. The server writes the integer `0` where there is
    /// no special use, which decodes to nil here.
    public let specialRole: String?
    public let unread: Int
    public let syncInBackground: Bool
    public let shared: Bool
    public let myAcls: String?
    public let cacheBuster: String?

    private enum CodingKeys: String, CodingKey {
        case databaseId
        case accountId
        case name
        case displayName
        case attributes
        case delimiter
        case specialUse
        case specialRole
        case unread
        case syncInBackground
        case shared
        case myAcls
        case cacheBuster
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .databaseId)
        accountId = try container.decode(Int.self, forKey: .accountId)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? name
        attributes = try container.decodeArray(String.self, forKey: .attributes)
        delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter) ?? "."
        specialUse = try container.decodeArray(String.self, forKey: .specialUse)
        specialRole = try container.decodeLenientString(forKey: .specialRole)
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        syncInBackground = try container.decodeLenientBool(forKey: .syncInBackground)
        shared = try container.decodeLenientBool(forKey: .shared)
        myAcls = try container.decodeIfPresent(String.self, forKey: .myAcls)
        cacheBuster = try container.decodeIfPresent(String.self, forKey: .cacheBuster)
    }

    /// Whether the user subscribed to this folder. ADR-0007 mirrors only these.
    ///
    /// Horde passes the server's casing through, so `\Subscribed` and
    /// `\subscribed` both occur and the comparison folds case.
    public var isSubscribed: Bool { hasAttribute("\\subscribed") }

    /// Whether the folder can be opened at all. `\noselect` marks a container
    /// that only holds children. The server computes the same thing into a
    /// `selectable` column and does not serialise it, so derive it here.
    public var isSelectable: Bool { !hasAttribute("\\noselect") && !hasAttribute("\\nonexistent") }

    /// The last path component, which is what a sidebar row shows.
    public var leafName: String {
        guard !delimiter.isEmpty else { return name }
        return name.components(separatedBy: delimiter).last ?? name
    }

    private func hasAttribute(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }
}

/// The envelope `GET /api/mailboxes?accountId=` wraps the folder list in.
///
/// `mailboxes` is flat: every folder's own `mailboxes` array is always empty
/// and the hierarchy lives in the names. `MailboxTree` (WS-07) rebuilds it.
public struct MailboxList: Decodable, Sendable, Hashable {
    public let accountId: Int
    public let email: String?
    public let delimiter: String
    /// The folders, each still carrying its own JSON so the store can fill
    /// `mailbox.rawJSON`. The wrapper is per folder rather than per response
    /// because that is the granularity the column has.
    public let entries: [RawBacked<Mailbox>]

    public var mailboxes: [Mailbox] { entries.map(\.value) }

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case delimiter
        case mailboxes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(Int.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter) ?? "."
        entries = try container.decodeArray(RawBacked<Mailbox>.self, forKey: .mailboxes)
    }
}
