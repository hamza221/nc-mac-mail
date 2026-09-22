// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

extension MailStore {
    /// Inserts or refreshes an account's mailboxes.
    ///
    /// `isMirrored` follows subscription ([ADR-0007](../../../../docs/decisions/0007-subscribed-mailboxes-only.md)),
    /// and is set here rather than by the caller so there is one place the rule lives. It is
    /// never cleared by a refresh: a mailbox that was mirrored and is now unsubscribed keeps
    /// what it has until the user asks for it to go.
    public func upsert(mailboxes: [MailboxWrite], accountId: Int64) async throws {
        guard !mailboxes.isEmpty else { return }
        try await dbQueue.write { db in
            for var mailbox in mailboxes {
                mailbox.accountId = accountId
                try mailbox.upsert(db)
                if mailbox.isSubscribed {
                    try db.execute(
                        sql: "UPDATE mailbox SET isMirrored = 1 WHERE id = ?",
                        arguments: [mailbox.id]
                    )
                }
            }
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
    public func observeMailboxes(accountId: Int64) -> AsyncValueObservation<[MailboxRecord]> {
        ValueObservation
            .tracking { db in try Self.fetchMailboxes(db, accountId: accountId) }
            .values(in: dbQueue, scheduling: .mainActor)
    }

    private static func fetchMailboxes(_ db: Database, accountId: Int64) throws -> [MailboxRecord] {
        try MailboxRecord.fetchAll(
            db,
            sql: "SELECT * FROM mailbox WHERE accountId = ? ORDER BY name",
            arguments: [accountId]
        )
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
