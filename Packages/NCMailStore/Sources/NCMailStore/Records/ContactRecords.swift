// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `addressBook`: one CardDAV collection of one login (ADR-0069).
///
/// `url` is the collection URL, which is CardDAV's identity for it. `syncToken` and
/// `lastSyncAt` are mirror bookkeeping and survive listing refreshes, exactly as
/// `mailbox.envelopeCursor` does; `isEnabled` is the user's own toggle and survives them
/// too.
public struct AddressBookRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "addressBook"

    public var id: Int64?
    public var loginId: Int64
    public var url: String
    public var displayName: String?
    public var isReadOnly: Bool
    /// Include this book in lists and autocomplete. The user's choice, never the server's.
    public var isEnabled: Bool
    public var position: Int
    /// RFC 6578 sync token. nil means never synced; `syncAddressBooks` preserves it.
    public var syncToken: String?
    public var lastSyncAt: Int64?

    public init(
        id: Int64? = nil,
        loginId: Int64,
        url: String,
        displayName: String? = nil,
        isReadOnly: Bool = false,
        isEnabled: Bool = true,
        position: Int = 0,
        syncToken: String? = nil,
        lastSyncAt: Int64? = nil
    ) {
        self.id = id
        self.loginId = loginId
        self.url = url
        self.displayName = displayName
        self.isReadOnly = isReadOnly
        self.isEnabled = isEnabled
        self.position = position
        self.syncToken = syncToken
        self.lastSyncAt = lastSyncAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `contact`: the raw vCard, lossless (ADR-0069), plus the display columns the
/// list and sort queries read so they never parse a vCard.
///
/// A group is a `KIND:group` vCard with `isGroup` set; its members are
/// ``ContactGroupMemberRecord`` rows keyed by the member's UID.
public struct ContactRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "contact"

    public var id: Int64?
    public var addressBookId: Int64
    /// The resource URL within the collection — CardDAV's identity for the card.
    public var href: String
    public var etag: String?
    public var uid: String?
    public var vcard: String
    public var displayName: String?
    public var givenName: String?
    public var familyName: String?
    public var nickname: String?
    public var organization: String?
    public var isGroup: Bool
    public var isFavorite: Bool
    public var syncedAt: Int64

    public init(
        id: Int64? = nil,
        addressBookId: Int64,
        href: String,
        etag: String? = nil,
        uid: String? = nil,
        vcard: String,
        displayName: String? = nil,
        givenName: String? = nil,
        familyName: String? = nil,
        nickname: String? = nil,
        organization: String? = nil,
        isGroup: Bool = false,
        isFavorite: Bool = false,
        syncedAt: Int64
    ) {
        self.id = id
        self.addressBookId = addressBookId
        self.href = href
        self.etag = etag
        self.uid = uid
        self.vcard = vcard
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.isGroup = isGroup
        self.isFavorite = isFavorite
        self.syncedAt = syncedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `contactEmail`: one address of one contact, in vCard order.
public struct ContactEmailRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "contactEmail"

    public var id: Int64?
    public var contactId: Int64
    public var position: Int
    public var email: String
    /// HOME|WORK|…, as the vCard spells it.
    public var type: String?
    public var isPreferred: Bool

    public init(
        id: Int64? = nil,
        contactId: Int64,
        position: Int,
        email: String,
        type: String? = nil,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.contactId = contactId
        self.position = position
        self.email = email
        self.type = type
        self.isPreferred = isPreferred
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `contactPhone`.
public struct ContactPhoneRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "contactPhone"

    public var id: Int64?
    public var contactId: Int64
    public var position: Int
    public var number: String
    public var type: String?
    public var isPreferred: Bool

    public init(
        id: Int64? = nil,
        contactId: Int64,
        position: Int,
        number: String,
        type: String? = nil,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.contactId = contactId
        self.position = position
        self.number = number
        self.type = type
        self.isPreferred = isPreferred
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `contactGroupMember`: one `MEMBER` of a group card, by the member's vCard UID.
///
/// Deliberately not a foreign key to `contact.id`: the member's card may not have arrived
/// yet when the group does, and deleting a member must not edit the group's vCard behind
/// CardDAV's back. Resolution is a join on `contact.uid`.
public struct ContactGroupMemberRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "contactGroupMember"

    public var id: Int64?
    public var groupId: Int64
    public var memberUid: String

    public init(id: Int64? = nil, groupId: Int64, memberUid: String) {
        self.id = id
        self.groupId = groupId
        self.memberUid = memberUid
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
