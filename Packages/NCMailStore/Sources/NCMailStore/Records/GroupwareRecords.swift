// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `calendar`: one CalDAV collection of one login, listed so iMIP replies and task
/// creation can offer a target. Calendars are listed, not synced — events stay on the server.
public struct CalendarRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "calendar"

    public var id: Int64?
    public var loginId: Int64
    public var url: String
    public var displayName: String?
    public var color: String?
    public var isWritable: Bool
    public var supportsEvents: Bool
    public var supportsTasks: Bool
    public var position: Int
    public var fetchedAt: Int64

    public init(
        id: Int64? = nil,
        loginId: Int64,
        url: String,
        displayName: String? = nil,
        color: String? = nil,
        isWritable: Bool = true,
        supportsEvents: Bool = true,
        supportsTasks: Bool = false,
        position: Int = 0,
        fetchedAt: Int64
    ) {
        self.id = id
        self.loginId = loginId
        self.url = url
        self.displayName = displayName
        self.color = color
        self.isWritable = isWritable
        self.supportsEvents = supportsEvents
        self.supportsTasks = supportsTasks
        self.position = position
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `team`: one circle from the Teams OCS API.
///
/// `remoteId` is TEXT because a circle's `singleId` is a string, unlike every Mail id.
public struct TeamRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "team"

    public var id: Int64?
    public var loginId: Int64
    public var remoteId: String
    public var displayName: String
    public var rawJSON: String
    public var fetchedAt: Int64

    public init(
        id: Int64? = nil,
        loginId: Int64,
        remoteId: String,
        displayName: String,
        rawJSON: String = "{}",
        fetchedAt: Int64
    ) {
        self.id = id
        self.loginId = loginId
        self.remoteId = remoteId
        self.displayName = displayName
        self.rawJSON = rawJSON
        self.fetchedAt = fetchedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `teamMember`.
public struct TeamMemberRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "teamMember"

    public var id: Int64?
    public var teamId: Int64
    public var userId: String
    public var displayName: String?
    public var email: String?
    public var rawJSON: String

    public init(
        id: Int64? = nil,
        teamId: Int64,
        userId: String,
        displayName: String? = nil,
        email: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.teamId = teamId
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.rawJSON = rawJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `snooze`: one hidden message and when it comes back.
///
/// `messageId` is the primary key — a message is snoozed once — and an INTEGER PRIMARY KEY
/// is a rowid alias, so the table stays observable (ADR-0025).
public struct SnoozeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "snooze"

    public var messageId: Int64
    public var until: Int64

    public init(messageId: Int64, until: Int64) {
        self.messageId = messageId
        self.until = until
    }
}
