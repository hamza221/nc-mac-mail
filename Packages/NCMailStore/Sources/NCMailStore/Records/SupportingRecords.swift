// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import GRDB

/// A row of `tag` — an IMAP keyword with the display name and colour the server gave it.
///
/// `id` is local and `remoteId` is the server's, for the reason in ADR-0033: tags belong to
/// an account server-side, so two accounts both numbering a tag 1 are two rows here.
public struct TagRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "tag"

    public var id: Int64
    public var accountId: Int64
    public var remoteId: Int64
    public var imapLabel: String
    public var displayName: String
    public var color: String?

    public init(
        id: Int64,
        accountId: Int64,
        remoteId: Int64,
        imapLabel: String,
        displayName: String,
        color: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.remoteId = remoteId
        self.imapLabel = imapLabel
        self.displayName = displayName
        self.color = color
    }
}

/// One tag as an envelope payload carries it. No local id: the envelope upsert finds or
/// creates the `tag` row by `(accountId, remoteId)` (ADR-0033).
public struct TagWrite: Sendable, Equatable {
    public var remoteId: Int64
    public var imapLabel: String
    public var displayName: String
    public var color: String?

    public init(remoteId: Int64, imapLabel: String, displayName: String, color: String? = nil) {
        self.remoteId = remoteId
        self.imapLabel = imapLabel
        self.displayName = displayName
        self.color = color
    }
}

/// A row of `messageTag`.
public struct MessageTagRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "messageTag"

    public var messageId: Int64
    public var tagId: Int64

    public init(messageId: Int64, tagId: Int64) {
        self.messageId = messageId
        self.tagId = tagId
    }
}

/// A row of `avatar`.
///
/// `missing` records a 404 so a sender with no avatar is not asked about again every launch.
/// The library draws coloured initials in that case and needs no bytes.
public struct AvatarRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "avatar"

    public var email: String
    public var data: Data?
    public var mime: String?
    public var isExternal: Bool
    public var missing: Bool
    public var fetchedAt: Int64

    public init(
        email: String,
        data: Data? = nil,
        mime: String? = nil,
        isExternal: Bool = false,
        missing: Bool = false,
        fetchedAt: Int64
    ) {
        self.email = email
        self.data = data
        self.mime = mime
        self.isExternal = isExternal
        self.missing = missing
        self.fetchedAt = fetchedAt
    }
}

/// A row of `pendingOperation`.
///
/// WS-06 inserts one of these in the same transaction as the local change it describes, which
/// is the whole of [ADR-0005](../../../../docs/decisions/0005-offline-mutation-queue.md).
/// `id` is nil before insertion; `didInsert` fills it.
public struct PendingOperationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pendingOperation"

    public var id: Int64?
    public var kind: String
    public var accountId: Int64
    public var messageId: Int64?
    public var threadRootId: String?
    public var mailboxId: Int64?
    /// Absolute intent, never a toggle: `{"seen":true}`, so replay is idempotent.
    public var payloadJSON: String
    public var createdAt: Int64
    /// `message.syncedAt` when the operation was queued, so the drainer can tell a conflict
    /// from a no-op without asking the server twice.
    public var baseSyncedAt: Int64
    public var state: PendingOperationState
    public var attempts: Int
    public var nextAttemptAt: Int64?
    public var lastError: String?

    public init(
        id: Int64? = nil,
        kind: String,
        accountId: Int64,
        messageId: Int64? = nil,
        threadRootId: String? = nil,
        mailboxId: Int64? = nil,
        payloadJSON: String,
        createdAt: Int64,
        baseSyncedAt: Int64,
        state: PendingOperationState = .pending,
        attempts: Int = 0,
        nextAttemptAt: Int64? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.accountId = accountId
        self.messageId = messageId
        self.threadRootId = threadRootId
        self.mailboxId = mailboxId
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.baseSyncedAt = baseSyncedAt
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of `meta`: app state not worth a table of its own.
public struct MetaRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "meta"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
