// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Drafts

extension MailStore {
    /// Creates a draft row and answers with it, local id assigned.
    @discardableResult
    public func insert(draft: DraftRecord) async throws -> DraftRecord {
        try await dbQueue.write { db in
            var row = draft
            row.id = nil
            try row.insert(db)
            return row
        }
    }

    /// Rewrites a draft row — the composer's autosave. Recipients and attachments have their
    /// own calls because they are edited at a different cadence than the body.
    public func update(draft: DraftRecord) async throws {
        try await dbQueue.write { db in try draft.update(db) }
    }

    public func draft(id: Int64) async throws -> DraftRecord? {
        try await dbQueue.read { db in
            try DraftRecord.fetchOne(db, sql: "SELECT * FROM draft WHERE id = ?", arguments: [id])
        }
    }

    /// One account's drafts, most recently edited first.
    public func drafts(accountId: Int64) async throws -> [DraftRecord] {
        try await dbQueue.read { db in
            try DraftRecord.fetchAll(
                db,
                sql: "SELECT * FROM draft WHERE accountId = ? ORDER BY updatedAt DESC, id DESC",
                arguments: [accountId]
            )
        }
    }

    public func observeDrafts(accountId: Int64) -> StoreObservation<[DraftRecord]> {
        observation { db in
            try DraftRecord.fetchAll(
                db,
                sql: "SELECT * FROM draft WHERE accountId = ? ORDER BY updatedAt DESC, id DESC",
                arguments: [accountId]
            )
        }
    }

    /// Discards a draft; recipients and attachments cascade.
    public func deleteDraft(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM draft WHERE id = ?", arguments: [id])
        }
    }

    /// Rewrites a draft's addressees wholesale, which is how the composer saves them:
    /// position is display order and renumbering in place would be the same writes anyway.
    public func replaceRecipients(_ recipients: [DraftRecipientRecord], draftId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM draftRecipient WHERE draftId = ?", arguments: [draftId])
            for recipient in recipients {
                var row = recipient
                row.id = nil
                row.draftId = draftId
                try row.insert(db)
            }
        }
    }

    public func recipients(draftId: Int64) async throws -> [DraftRecipientRecord] {
        try await dbQueue.read { db in
            try DraftRecipientRecord.fetchAll(
                db,
                sql: "SELECT * FROM draftRecipient WHERE draftId = ? ORDER BY kind, position",
                arguments: [draftId]
            )
        }
    }

    /// Adds one attachment row and answers with it. Attachments are added and removed one at
    /// a time — a drop, an upload finishing — unlike recipients.
    @discardableResult
    public func insert(draftAttachment: DraftAttachmentRecord) async throws -> DraftAttachmentRecord {
        try await dbQueue.write { db in
            var row = draftAttachment
            row.id = nil
            try row.insert(db)
            return row
        }
    }

    /// Rewrites one attachment row — in practice: stamping `remoteAttachmentId` after the
    /// upload finishes.
    public func update(draftAttachment: DraftAttachmentRecord) async throws {
        try await dbQueue.write { db in try draftAttachment.update(db) }
    }

    public func deleteDraftAttachment(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM draftAttachment WHERE id = ?", arguments: [id])
        }
    }

    public func attachments(draftId: Int64) async throws -> [DraftAttachmentRecord] {
        try await dbQueue.read { db in
            try DraftAttachmentRecord.fetchAll(
                db,
                sql: "SELECT * FROM draftAttachment WHERE draftId = ? ORDER BY id",
                arguments: [draftId]
            )
        }
    }
}

// MARK: - Outbox

extension MailStore {
    /// Replaces one account's mirrored outbox with what `GET /api/outbox` just said.
    ///
    /// Replace, not upsert: the server owns every column, the list is small, and a message
    /// that left the queue (sent, or cancelled elsewhere) must disappear here too.
    public func replaceOutbox(_ messages: [OutboxMessageRecord], accountId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outboxMessage WHERE accountId = ?", arguments: [accountId])
            for message in messages {
                var row = message
                row.id = nil
                row.accountId = accountId
                try row.insert(db)
            }
        }
    }

    /// Every queued message across accounts, soonest send first, which is the Outbox view's
    /// order. Unscheduled messages sort after scheduled ones.
    public func outboxMessages() async throws -> [OutboxMessageRecord] {
        try await dbQueue.read { db in
            try OutboxMessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM outboxMessage ORDER BY sendAt IS NULL, sendAt, id"
            )
        }
    }

    public func observeOutboxMessages() -> StoreObservation<[OutboxMessageRecord]> {
        observation { db in
            try OutboxMessageRecord.fetchAll(
                db,
                sql: "SELECT * FROM outboxMessage ORDER BY sendAt IS NULL, sendAt, id"
            )
        }
    }
}
