// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// A row of `account`, as read.
///
/// The column names are the property names, which is why the schema is camelCase: no
/// `CodingKeys`, and a column rename is a compile error rather than a silent nil.
public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "account"

    public var id: Int64
    public var name: String
    public var emailAddress: String
    public var sortOrder: Int
    public var draftsMailboxId: Int64?
    public var sentMailboxId: Int64?
    public var trashMailboxId: Int64?
    /// Null on a live server that has no archive folder configured, which is the common case
    /// rather than a rare one. Nothing may assume this is set.
    public var archiveMailboxId: Int64?
    public var junkMailboxId: Int64?
    public var snoozeMailboxId: Int64?
    public var showSubscribedOnly: Bool
    public var quotaPercentage: Int?
    public var signature: String?
    public var mirrorState: MirrorState
    public var lastSyncAt: Int64?
    public var lastDeepReconcileAt: Int64?
    public var rawJSON: String

    public init(
        id: Int64,
        name: String,
        emailAddress: String,
        sortOrder: Int = 0,
        draftsMailboxId: Int64? = nil,
        sentMailboxId: Int64? = nil,
        trashMailboxId: Int64? = nil,
        archiveMailboxId: Int64? = nil,
        junkMailboxId: Int64? = nil,
        snoozeMailboxId: Int64? = nil,
        showSubscribedOnly: Bool = false,
        quotaPercentage: Int? = nil,
        signature: String? = nil,
        mirrorState: MirrorState = .idle,
        lastSyncAt: Int64? = nil,
        lastDeepReconcileAt: Int64? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
        self.sortOrder = sortOrder
        self.draftsMailboxId = draftsMailboxId
        self.sentMailboxId = sentMailboxId
        self.trashMailboxId = trashMailboxId
        self.archiveMailboxId = archiveMailboxId
        self.junkMailboxId = junkMailboxId
        self.snoozeMailboxId = snoozeMailboxId
        self.showSubscribedOnly = showSubscribedOnly
        self.quotaPercentage = quotaPercentage
        self.signature = signature
        self.mirrorState = mirrorState
        self.lastSyncAt = lastSyncAt
        self.lastDeepReconcileAt = lastDeepReconcileAt
        self.rawJSON = rawJSON
    }
}

/// The columns of `account` the server owns.
///
/// Writing this rather than a whole ``AccountRecord`` is what keeps a sync from resetting
/// `mirrorState` and `lastDeepReconcileAt` to whatever the caller happened to have in hand:
/// a column that is not in the INSERT is not in the `DO UPDATE SET` either. See ADR-0023.
public struct AccountWrite: Codable, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "account"

    public var id: Int64
    public var name: String
    public var emailAddress: String
    public var sortOrder: Int
    public var draftsMailboxId: Int64?
    public var sentMailboxId: Int64?
    public var trashMailboxId: Int64?
    public var archiveMailboxId: Int64?
    public var junkMailboxId: Int64?
    public var snoozeMailboxId: Int64?
    public var showSubscribedOnly: Bool
    public var quotaPercentage: Int?
    public var signature: String?
    public var rawJSON: String

    public init(
        id: Int64,
        name: String,
        emailAddress: String,
        sortOrder: Int = 0,
        draftsMailboxId: Int64? = nil,
        sentMailboxId: Int64? = nil,
        trashMailboxId: Int64? = nil,
        archiveMailboxId: Int64? = nil,
        junkMailboxId: Int64? = nil,
        snoozeMailboxId: Int64? = nil,
        showSubscribedOnly: Bool = false,
        quotaPercentage: Int? = nil,
        signature: String? = nil,
        rawJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.emailAddress = emailAddress
        self.sortOrder = sortOrder
        self.draftsMailboxId = draftsMailboxId
        self.sentMailboxId = sentMailboxId
        self.trashMailboxId = trashMailboxId
        self.archiveMailboxId = archiveMailboxId
        self.junkMailboxId = junkMailboxId
        self.snoozeMailboxId = snoozeMailboxId
        self.showSubscribedOnly = showSubscribedOnly
        self.quotaPercentage = quotaPercentage
        self.signature = signature
        self.rawJSON = rawJSON
    }
}
