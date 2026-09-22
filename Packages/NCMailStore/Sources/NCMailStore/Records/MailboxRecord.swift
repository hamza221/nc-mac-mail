// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `mailbox`, as read.
public struct MailboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "mailbox"

    public var id: Int64
    public var accountId: Int64
    /// The full IMAP path, delimiter and all. The tree builder in `NCMailCore` splits it.
    public var name: String
    public var delimiter: String?
    public var displayName: String
    /// Left as a string rather than an enum: the server sends `specialUse[0] ?? 0`, so an
    /// unmodelled role must round-trip instead of failing a decode on someone's mailbox.
    public var specialRole: String?
    public var specialUseJSON: String
    public var attributesJSON: String
    public var isSubscribed: Bool
    public var isSelectable: Bool
    public var syncInBackground: Bool
    public var unreadCount: Int
    public var totalCount: Int?
    public var cacheBuster: String?
    public var isMirrored: Bool
    public var envelopeCursor: Int64?
    public var envelopesComplete: Bool
    public var bodiesComplete: Bool
    public var lastSyncAt: Int64?
    public var lastPrimedAt: Int64?
    public var syncFailureCount: Int
    public var lastSyncError: String?
    public var rawJSON: String

    public init(
        id: Int64,
        accountId: Int64,
        name: String,
        delimiter: String? = nil,
        displayName: String,
        specialRole: String? = nil,
        specialUseJSON: String = "[]",
        attributesJSON: String = "[]",
        isSubscribed: Bool = false,
        isSelectable: Bool = true,
        syncInBackground: Bool = false,
        unreadCount: Int = 0,
        totalCount: Int? = nil,
        cacheBuster: String? = nil,
        isMirrored: Bool = false,
        envelopeCursor: Int64? = nil,
        envelopesComplete: Bool = false,
        bodiesComplete: Bool = false,
        lastSyncAt: Int64? = nil,
        lastPrimedAt: Int64? = nil,
        syncFailureCount: Int = 0,
        lastSyncError: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.delimiter = delimiter
        self.displayName = displayName
        self.specialRole = specialRole
        self.specialUseJSON = specialUseJSON
        self.attributesJSON = attributesJSON
        self.isSubscribed = isSubscribed
        self.isSelectable = isSelectable
        self.syncInBackground = syncInBackground
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.cacheBuster = cacheBuster
        self.isMirrored = isMirrored
        self.envelopeCursor = envelopeCursor
        self.envelopesComplete = envelopesComplete
        self.bodiesComplete = bodiesComplete
        self.lastSyncAt = lastSyncAt
        self.lastPrimedAt = lastPrimedAt
        self.syncFailureCount = syncFailureCount
        self.lastSyncError = lastSyncError
        self.rawJSON = rawJSON
    }
}

/// The columns of `mailbox` the server owns, plus the one the store derives from them.
///
/// `isMirrored`, `envelopeCursor`, `envelopesComplete`, `bodiesComplete`, `lastPrimedAt`,
/// `syncFailureCount` and `lastSyncError` are absent on purpose. They are the mirror's own
/// progress, and a folder refresh must not roll it back to zero. See ADR-0023.
public struct MailboxWrite: Codable, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "mailbox"

    public var id: Int64
    public var accountId: Int64
    public var name: String
    public var delimiter: String?
    public var displayName: String
    public var specialRole: String?
    public var specialUseJSON: String
    public var attributesJSON: String
    public var isSubscribed: Bool
    public var isSelectable: Bool
    public var syncInBackground: Bool
    public var unreadCount: Int
    public var totalCount: Int?
    public var cacheBuster: String?
    public var rawJSON: String

    public init(
        id: Int64,
        accountId: Int64,
        name: String,
        delimiter: String? = nil,
        displayName: String,
        specialRole: String? = nil,
        specialUseJSON: String = "[]",
        attributesJSON: String = "[]",
        isSubscribed: Bool = false,
        isSelectable: Bool = true,
        syncInBackground: Bool = false,
        unreadCount: Int = 0,
        totalCount: Int? = nil,
        cacheBuster: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.delimiter = delimiter
        self.displayName = displayName
        self.specialRole = specialRole
        self.specialUseJSON = specialUseJSON
        self.attributesJSON = attributesJSON
        self.isSubscribed = isSubscribed
        self.isSelectable = isSelectable
        self.syncInBackground = syncInBackground
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.cacheBuster = cacheBuster
        self.rawJSON = rawJSON
    }
}
