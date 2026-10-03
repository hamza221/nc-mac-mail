// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// Inserts or refreshes an account's mailboxes.
    ///
    /// `isMirrored` follows subscription ([ADR-0007](../../../../docs/decisions/0007-subscribed-mailboxes-only.md)),
    /// and is set here rather than by the caller so there is one place the rule lives. It is
    /// never cleared by a refresh: a mailbox that was mirrored and is now unsubscribed keeps
    /// what it has until the user asks for it to go.
    @discardableResult
    public func upsert(mailboxes: [MailboxWrite], accountId: Int64) async throws -> [MailboxRecord] {
        guard !mailboxes.isEmpty else { return [] }
        return try await dbQueue.write { db in
            try mailboxes.map { write in
                var mailbox = write
                mailbox.accountId = accountId
                // `upsertAndFetch` rather than `upsert`: the local id is assigned here and
                // the caller has no other way to learn it (ADR-0033).
                let record = try mailbox.upsertAndFetch(db, as: MailboxRecord.self)
                guard mailbox.isSubscribed, !record.isMirrored else { return record }
                try db.execute(
                    sql: "UPDATE mailbox SET isMirrored = 1 WHERE id = ?",
                    arguments: [record.id]
                )
                var mirrored = record
                mirrored.isMirrored = true
                return mirrored
            }
        }
    }

    /// One mailbox by its local id.
    public func mailbox(id: Int64) async throws -> MailboxRecord? {
        try await dbQueue.read { db in
            try MailboxRecord.fetchOne(db, sql: "SELECT * FROM mailbox WHERE id = ?", arguments: [id])
        }
    }

    public func mailboxes(accountId: Int64) async throws -> [MailboxRecord] {
        try await dbQueue.read { db in try Self.fetchMailboxes(db, accountId: accountId) }
    }

    /// The sidebar's mailboxes for one account, live.
    ///
    /// Rows, not a tree. Building the tree is a pure function over these rows and lives in
    /// `NCMailCore` where it can be tested without a database — see ADR-0023 for why the store
    /// does not do it.
    public func observeMailboxes(accountId: Int64) -> StoreObservation<[MailboxRecord]> {
        observation { db in try Self.fetchMailboxes(db, accountId: accountId) }
    }

    /// One mailbox, live.
    ///
    /// The mirror's progress columns — `envelopesComplete` above all — change while the
    /// mailbox is on screen, and an empty list reads differently depending on which of them
    /// is set. Nil once the row is gone, which is what a deleted or unsubscribed folder
    /// looks like from a view still pointed at it.
    public func observeMailbox(id: Int64) -> StoreObservation<MailboxRecord?> {
        observation { db in
            try MailboxRecord.fetchOne(db, sql: "SELECT * FROM mailbox WHERE id = ?", arguments: [id])
        }
    }

    /// The rows, with `unreadCount` taken from the mirror wherever the mirror is complete.
    ///
    /// The column holds the server's figure, written only by a folder refresh or a stats
    /// call, so on its own it ignores every local change: opening a message, `U`, a move,
    /// a delete, all of it offline. Once a mailbox's envelopes are complete the mirror *is*
    /// the mailbox, so its own `isSeen` count is the right number and moves with every write.
    /// Until then, and for a mailbox that is not mirrored, the local count would undercount,
    /// so the server's figure stands. ADR-0060.
    ///
    /// One grouped count per fetch, served by `idxMessageMailboxSeen`. Reading `message`
    /// also puts it in the observation's region, which is what makes the sidebar redraw when
    /// a flag changes.
    private static func fetchMailboxes(_ db: Database, accountId: Int64) throws -> [MailboxRecord] {
        let mailboxes = try MailboxRecord.fetchAll(
            db,
            sql: "SELECT * FROM mailbox WHERE accountId = ? ORDER BY name",
            arguments: [accountId]
        )
        let localUnread = try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: """
                    SELECT mailboxId, count(*) AS unread FROM message
                    WHERE accountId = ? AND isSeen = 0
                    GROUP BY mailboxId
                    """,
                arguments: [accountId]
            ).map { row -> (Int64, Int) in (row["mailboxId"], row["unread"]) }
        )
        return mailboxes.map { mailbox in
            guard mailbox.isMirrored, mailbox.envelopesComplete else { return mailbox }
            var counted = mailbox
            counted.unreadCount = localUnread[mailbox.id] ?? 0
            return counted
        }
    }

    /// Advances stage 1's cursor. The caller writes this in the same transaction as the page of
    /// envelopes it came from, which is the only thing that makes a crash mid-page harmless.
    public func setEnvelopeCursor(
        _ cursor: Int64?,
        complete: Bool,
        mailboxId: Int64,
        lastSyncAt: Int64
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE mailbox
                       SET envelopeCursor = :cursor,
                           envelopesComplete = :complete,
                           lastSyncAt = :lastSyncAt,
                           syncFailureCount = 0,
                           lastSyncError = NULL
                     WHERE id = :id
                    """,
                arguments: [
                    "cursor": cursor, "complete": complete, "lastSyncAt": lastSyncAt, "id": mailboxId,
                ]
            )
        }
    }

    /// Stamps a successful stage-0 prime.
    ///
    /// Its own method rather than a column on ``MailboxWrite``: `lastPrimedAt` is mirror
    /// bookkeeping, and a folder refresh must not be able to roll it back (ADR-0023). WS-04
    /// wrote this as raw SQL through the store's `write`, which is what kept GRDB in the
    /// store's public interface; it is a DAO now.
    public func setLastPrimedAt(_ primedAt: Int64, mailboxId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET lastPrimedAt = ? WHERE id = ?",
                arguments: [primedAt, mailboxId]
            )
        }
    }

    /// Records a failed sync against one mailbox. One slow or broken mailbox must never stop
    /// the account, so this counts rather than throws.
    public func recordSyncFailure(mailboxId: Int64, message: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE mailbox
                       SET syncFailureCount = syncFailureCount + 1, lastSyncError = :message
                     WHERE id = :id
                    """,
                arguments: ["message": message, "id": mailboxId]
            )
        }
    }
}
