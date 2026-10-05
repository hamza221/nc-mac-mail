// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

// MARK: - Tags

extension MailStore {
    /// One account's tags, by display name.
    public func tags(accountId: Int64) async throws -> [TagRecord] {
        try await dbQueue.read { db in try Self.fetchTags(db, accountId: accountId) }
    }

    public func observeTags(accountId: Int64) -> StoreObservation<[TagRecord]> {
        observation { db in try Self.fetchTags(db, accountId: accountId) }
    }

    /// The tags on one message, by display name.
    public func tags(messageId: Int64) async throws -> [TagRecord] {
        try await dbQueue.read { db in
            try TagRecord.fetchAll(
                db,
                sql: """
                    SELECT tag.* FROM tag
                    JOIN messageTag ON messageTag.tagId = tag.id
                    WHERE messageTag.messageId = ?
                    ORDER BY tag.displayName, tag.id
                    """,
                arguments: [messageId]
            )
        }
    }

    private static func fetchTags(_ db: Database, accountId: Int64) throws -> [TagRecord] {
        try TagRecord.fetchAll(
            db,
            sql: "SELECT * FROM tag WHERE accountId = ? ORDER BY displayName, id",
            arguments: [accountId]
        )
    }

    /// Upserts each tag by `(accountId, remoteId)` and rewrites the message's `messageTag`
    /// rows to exactly these. Runs inside the envelope upsert's transaction.
    static func replaceTags(_ tags: [TagWrite], messageId: Int64, accountId: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM messageTag WHERE messageId = ?", arguments: [messageId])
        guard !tags.isEmpty else { return }
        let upsert = try db.cachedStatement(
            sql: """
                INSERT INTO tag (accountId, remoteId, imapLabel, displayName, color)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (accountId, remoteId) DO UPDATE SET
                    imapLabel = excluded.imapLabel,
                    displayName = excluded.displayName,
                    color = excluded.color
                RETURNING id
                """
        )
        let link = try db.cachedStatement(
            sql: "INSERT OR IGNORE INTO messageTag (messageId, tagId) VALUES (?, ?)"
        )
        for tag in tags {
            upsert.arguments = [accountId, tag.remoteId, tag.imapLabel, tag.displayName, tag.color]
            guard let tagId = try Int64.fetchOne(upsert) else {
                throw MailStoreError.rowVanished(table: "tag", remoteId: tag.remoteId)
            }
            link.arguments = [messageId, tagId]
            try link.execute()
        }
    }
}
