// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

extension MailStore {
    /// Inserts or refreshes accounts, leaving every mirror-bookkeeping column alone.
    public func upsert(accounts: [AccountWrite]) async throws {
        guard !accounts.isEmpty else { return }
        try await dbQueue.write { db in
            for account in accounts {
                try account.upsert(db)
            }
        }
    }

    public func accounts() async throws -> [AccountRecord] {
        try await dbQueue.read { db in
            try AccountRecord.fetchAll(db, sql: "SELECT * FROM account ORDER BY sortOrder, id")
        }
    }

    /// The sidebar's account sections, live.
    public func observeAccounts() -> AsyncValueObservation<[AccountRecord]> {
        ValueObservation
            .tracking { db in
                try AccountRecord.fetchAll(db, sql: "SELECT * FROM account ORDER BY sortOrder, id")
            }
            .values(in: dbQueue, scheduling: .mainActor)
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
    /// and queued operations; the `messageSearch` trigger takes the index rows with them. The
    /// caller is expected to `VACUUM` afterwards, which is a separate call because it is slow
    /// and belongs to a progress indicator rather than to a transaction.
    public func deleteAccount(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id])
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

    /// Rebuilds the file so the pages a delete freed go back to the file system.
    ///
    /// Outside any transaction, and slow on a large mirror, which is why it is not folded into
    /// ``deleteAccount(id:)``.
    public func vacuum() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
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
