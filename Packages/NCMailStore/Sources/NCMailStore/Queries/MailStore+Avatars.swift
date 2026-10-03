// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// The stored avatar for one email address, or nil if nothing has been recorded for it.
    ///
    /// The picture of a person, keyed by address and shared across accounts and servers,
    /// because the same person has the same address on both (ADR-0033).
    ///
    /// Three answers, and the caller needs all three. Nil means nobody has asked the server
    /// yet. A row with ``AvatarRecord/missing`` set means the server answered 404, and the
    /// fetcher will not ask again until the row is stale — the library draws coloured
    /// initials and needs no bytes. Anything else carries ``AvatarRecord/data``.
    ///
    /// The address is matched case-insensitively: a header may spell it any way and it is
    /// still the same mailbox.
    public func avatar(for email: String) async throws -> AvatarRecord? {
        try await dbQueue.read { db in
            try AvatarRecord.fetchOne(
                db,
                sql: "SELECT * FROM avatar WHERE email = ? COLLATE NOCASE",
                arguments: [email]
            )
        }
    }

    /// One address's avatar row, live. The app's loader waits on this, so a photo the fetcher
    /// writes after a row was drawn still replaces the initials, and the view never asks the
    /// network.
    public func observeAvatar(for email: String) -> StoreObservation<AvatarRecord?> {
        observation { db in
            try AvatarRecord.fetchOne(
                db,
                sql: "SELECT * FROM avatar WHERE email = ? COLLATE NOCASE",
                arguments: [email]
            )
        }
    }

    /// Records what the server said about one address: the bytes, or `missing` for a 404.
    /// The key is lowercased, so the same person spelled two ways is one row.
    public func upsert(avatar: AvatarRecord) async throws {
        var lowered = avatar
        lowered.email = avatar.email.lowercased()
        let row = lowered
        try await dbQueue.write { db in try row.upsert(db) }
    }

    /// Senders of this account's mail that need asking about, newest correspondent first,
    /// so that the people at the top of the inbox get their pictures first.
    ///
    /// An address needs asking if it has no row, if its photo is older than `staleBefore`,
    /// or if its 404 is older than `retryMissingBefore`. The two cutoffs differ because a
    /// person who sets a Gravatar today should not wait a month for it to show.
    public func sendersNeedingAvatars(
        accountId: Int64,
        staleBefore: Int64,
        retryMissingBefore: Int64,
        limit: Int
    ) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT lower(m.fromEmail) AS email
                    FROM message m
                    WHERE m.accountId = :accountId AND m.fromEmail IS NOT NULL AND m.fromEmail != ''
                      AND NOT EXISTS (
                        SELECT 1 FROM avatar a
                         WHERE a.email = lower(m.fromEmail)
                           AND (
                                (a.missing = 0 AND a.fetchedAt >= :staleBefore)
                             OR (a.missing = 1 AND a.fetchedAt >= :retryMissingBefore)
                           )
                      )
                    GROUP BY lower(m.fromEmail)
                    ORDER BY max(m.sentAt) DESC
                    LIMIT :limit
                    """,
                arguments: [
                    "accountId": accountId,
                    "staleBefore": staleBefore,
                    "retryMissingBefore": retryMissingBefore,
                    "limit": limit,
                ]
            )
        }
    }
}
