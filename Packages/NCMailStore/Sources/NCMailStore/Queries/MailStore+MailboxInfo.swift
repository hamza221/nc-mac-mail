// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// One mailbox's local counts, once.
    public func mailboxCounts(mailboxId: Int64) async throws -> MailboxCounts {
        try await dbQueue.read { db in try Self.fetchMailboxCounts(db, mailboxId: mailboxId) }
    }

    /// One mailbox's local counts, live.
    ///
    /// The Get info panel stays open while the backfill runs and while the user triages, so
    /// a one-shot read would go stale exactly when someone is watching it move.
    public func observeMailboxCounts(mailboxId: Int64) -> StoreObservation<MailboxCounts> {
        observation { db in try Self.fetchMailboxCounts(db, mailboxId: mailboxId) }
    }

    /// One pass over the mailbox's rows rather than four counts: `idxMessageMailboxSent`
    /// narrows to the mailbox, and every figure is a sum over the same rows. Unread is counted
    /// the way `fetchMailboxes` counts it (ADR-0060), so the panel and the sidebar agree.
    private static func fetchMailboxCounts(_ db: Database, mailboxId: Int64) throws -> MailboxCounts {
        let counts = try MailboxCounts.fetchOne(
            db,
            sql: """
                SELECT
                    count(*) AS messageCount,
                    coalesce(sum(isSeen = 0), 0) AS unreadCount,
                    coalesce(sum(bodyState = 'present'), 0) AS bodiesPresent,
                    coalesce(sum(bodyState = 'failed'), 0) AS bodiesFailed
                FROM message
                WHERE mailboxId = ?
                """,
            arguments: [mailboxId]
        )
        // An aggregate without GROUP BY returns exactly one row, even over no rows.
        return counts ?? .empty
    }
}
