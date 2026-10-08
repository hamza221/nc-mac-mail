// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// Inserts or refreshes accounts, leaving every mirror-bookkeeping column alone, and
    /// answers with the rows as they now stand.
    ///
    /// The rows are what the caller wants. An ``AccountWrite`` carries the server's id and
    /// the login it came from; the local id that scopes every mailbox and message under it
    /// is the mirror's to assign. `UNIQUE (serverURL, loginName, remoteId)` is the conflict
    /// target, so the same account from the same login updates its row, and the same numeric
    /// id from a second server inserts a new one (ADR-0033).
    @discardableResult
    public func upsert(accounts: [AccountWrite]) async throws -> [AccountRecord] {
        guard !accounts.isEmpty else { return [] }
        return try await dbQueue.write { db in
            try accounts.map { try $0.upsertAndFetch(db, as: AccountRecord.self) }
        }
    }

    /// One account by its local id, for a caller that has an id and needs the server and
    /// login it belongs to.
    public func account(id: Int64) async throws -> AccountRecord? {
        try await dbQueue.read { db in
            try AccountRecord.fetchOne(db, sql: "SELECT * FROM account WHERE id = ?", arguments: [id])
        }
    }

    /// Every account mirrored for one signed-in login, in sidebar order.
    public func accounts(identity: ServerIdentity) async throws -> [AccountRecord] {
        let sql =
            "SELECT * FROM account WHERE serverURL = :serverURL AND loginName = :loginName"
            + " ORDER BY sortOrder, id"
        return try await dbQueue.read { db in
            try AccountRecord.fetchAll(
                db,
                sql: sql,
                arguments: ["serverURL": identity.serverURL, "loginName": identity.loginName]
            )
        }
    }

    public func accounts() async throws -> [AccountRecord] {
        try await dbQueue.read { db in
            try AccountRecord.fetchAll(db, sql: "SELECT * FROM account ORDER BY sortOrder, id")
        }
    }

    /// The sidebar's account sections, live.
    public func observeAccounts() -> StoreObservation<[AccountRecord]> {
        observation { db in
            try AccountRecord.fetchAll(db, sql: "SELECT * FROM account ORDER BY sortOrder, id")
        }
    }

    /// Records where the account's mirror has got to.
    public func setMirrorState(_ state: MirrorState, accountId: Int64, lastSyncAt: Int64? = nil) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE account
                       SET mirrorState = :state,
                           lastSyncAt = coalesce(:lastSyncAt, lastSyncAt)
                     WHERE id = :id
                    """,
                arguments: ["state": state.rawValue, "lastSyncAt": lastSyncAt, "id": accountId]
            )
        }
    }

    /// Removes an account and everything that hangs off it.
    ///
    /// The foreign keys cascade to mailboxes, messages, addresses, bodies, attachments, tags
    /// and queued operations; the `messageSearch` trigger takes the index rows with them.
    /// `avatar` is shared across accounts and no cascade reaches it, so the rows no remaining
    /// message names go in the same transaction. The caller is expected to call ``vacuum()``
    /// afterwards, which is what makes the removal physical, and a separate call because it
    /// is slow and belongs to a progress indicator rather than to a transaction.
    public func deleteAccount(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id])
            try Self.deleteUnreferencedAvatars(db)
        }
        storeLog.info("account \(id, privacy: .public) removed from the mirror")
    }

    /// Reclaims the space an account's bodies take, keeping every envelope.
    ///
    /// Settings › Storage calls this. The app stays fully usable afterwards: bodies re-fetch
    /// when opened, and resetting `bodyState` restarts stage 2 where it left off.
    public func removeLocalCopies(accountId: Int64, resetBodyState: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM messageBody
                     WHERE messageId IN (SELECT id FROM message WHERE accountId = ?)
                    """,
                arguments: [accountId]
            )
            try db.execute(
                sql: """
                    UPDATE attachment SET data = NULL, fetchedAt = NULL
                     WHERE messageId IN (SELECT id FROM message WHERE accountId = ?)
                    """,
                arguments: [accountId]
            )
            try SearchIndexWriter.clearBodies(accountId: accountId, in: db)
            if resetBodyState {
                try db.execute(
                    sql: "UPDATE message SET bodyState = 'missing' WHERE accountId = ?",
                    arguments: [accountId]
                )
                try db.execute(
                    sql: "UPDATE mailbox SET bodiesComplete = 0 WHERE accountId = ?",
                    arguments: [accountId]
                )
            }
        }
    }

    /// Rebuilds the file so that what a removal deleted is gone from the disk, not only from
    /// every query, and the pages it freed go back to the file system.
    ///
    /// Every removal path calls this straight after, and it is where "removed" becomes
    /// physical (ADR-0105):
    ///
    /// - FTS5 `rebuild` rewrites each search index from its table's own content. A delete or
    ///   a cleared body only appends a marker that hides the old postings from queries; the
    ///   postings stay in `messageSearch_data` and `contactSearch_data`, live pages that
    ///   `VACUUM` would copy. `optimize` is not enough: measured, it left removed words in the
    ///   merged segment.
    /// - `VACUUM` copies only live pages into a new file, so freed pages holding old rows,
    ///   bodies and index segments are not carried over.
    /// - The `TRUNCATE` checkpoint moves the vacuumed pages from the write-ahead log into the
    ///   file and empties the log, which otherwise still holds them, and older frames too,
    ///   until SQLite next checkpoints on its own.
    ///
    /// Outside any transaction, and slow on a large mirror, which is why it is not folded into
    /// ``deleteAccount(id:)``.
    public func vacuum() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO messageSearch(messageSearch) VALUES ('rebuild')")
            try db.execute(sql: "INSERT INTO contactSearch(contactSearch) VALUES ('rebuild')")
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func mirrorProgress(accountId: Int64) async throws -> MirrorProgress {
        try await dbQueue.read { db in
            let progress = try MirrorProgress.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT count(*) FROM message WHERE accountId = :id)
                            AS totalMessages,
                        (SELECT count(*) FROM message WHERE accountId = :id AND bodyState = 'present')
                            AS bodiesPresent,
                        (SELECT count(*) FROM message WHERE accountId = :id AND bodyState = 'failed')
                            AS bodiesFailed,
                        (SELECT count(*) FROM mailbox
                          WHERE accountId = :id AND isMirrored = 1 AND envelopesComplete = 0)
                            AS mailboxesRemaining
                    """,
                arguments: ["id": accountId]
            )
            // The SELECT has no FROM clause, so it returns exactly one row, always.
            return progress
                ?? MirrorProgress(
                    totalMessages: 0,
                    bodiesPresent: 0,
                    bodiesFailed: 0,
                    mailboxesRemaining: 0
                )
        }
    }

    public func storageFootprint(accountId: Int64) async throws -> StorageFootprint {
        try await dbQueue.read { db in
            let footprint = try StorageFootprint.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT count(*) FROM message WHERE accountId = :id)
                            AS messageCount,
                        (SELECT count(*) FROM messageBody b
                           JOIN message m ON m.id = b.messageId WHERE m.accountId = :id)
                            AS bodyCount,
                        (SELECT coalesce(sum(b.byteSize), 0) FROM messageBody b
                           JOIN message m ON m.id = b.messageId WHERE m.accountId = :id)
                            AS bodyBytes,
                        (SELECT coalesce(sum(length(a.data)), 0) FROM attachment a
                           JOIN message m ON m.id = a.messageId WHERE m.accountId = :id)
                            AS attachmentBytes
                    """,
                arguments: ["id": accountId]
            )
            return footprint ?? StorageFootprint(messageCount: 0, bodyCount: 0, bodyBytes: 0, attachmentBytes: 0)
        }
    }
}
