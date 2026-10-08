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
    /// The address is matched case-insensitively, folded the one way every avatar query
    /// folds it (see ``upsert(avatar:accountId:)``): a header may spell it any way and it is
    /// still the same mailbox.
    public func avatar(for email: String) async throws -> AvatarRecord? {
        try await dbQueue.read { db in
            try AvatarRecord.fetchOne(db, sql: "SELECT * FROM avatar WHERE email = lower(?)", arguments: [email])
        }
    }

    /// One address's avatar row, live. The app's loader waits on this, so a photo the fetcher
    /// writes after a row was drawn still replaces the initials, and the view never asks the
    /// network.
    public func observeAvatar(for email: String) -> StoreObservation<AvatarRecord?> {
        observation { db in
            try AvatarRecord.fetchOne(db, sql: "SELECT * FROM avatar WHERE email = lower(?)", arguments: [email])
        }
    }

    /// Records what the server said about one address while fetching for `accountId`: the
    /// bytes, or `missing` for a 404.
    ///
    /// The key is SQLite's `lower()` of the address, computed by SQLite, and every avatar
    /// query compares against `lower()` too. GRDB links the system SQLite, built without
    /// ICU, so `lower()` folds ASCII only. Swift's `lowercased()` folds all of Unicode, and
    /// this writer once used it: `Ö@` was stored as `ö@`, never retired its own work-list
    /// entry, and the fetcher asked about it forever, while the Kelvin sign (U+212A) folded
    /// to `k` and overwrote another sender's photo (ADR-0104). One fold, done in one place
    /// by one engine, is what makes the row written for an address the row that takes it off
    /// ``sendersNeedingAvatars(accountId:staleBefore:retryMissingBefore:limit:)``.
    ///
    /// Nothing is written once the account is gone. Its fetcher stops after the account row
    /// disappears, not before, so an answer already in flight would otherwise land after
    /// ``deleteAccount(id:)`` removed the addresses only that account's mail named, and bring
    /// one back.
    public func upsert(avatar: AvatarRecord, accountId: Int64) async throws {
        let record = avatar
        try await dbQueue.write { db in
            try Self.upsert(record, in: db, onlyWhileAccountExists: accountId)
        }
    }

    /// Records a contact's photo, or hands an address back to the server's answer, keyed the
    /// same way as ``upsert(avatar:accountId:)``. Contacts belong to a login rather than an
    /// account, so there is no account to require.
    public func upsert(avatar: AvatarRecord) async throws {
        let record = avatar
        try await dbQueue.write { db in
            try Self.upsert(record, in: db, onlyWhileAccountExists: nil)
        }
    }

    private static func upsert(_ record: AvatarRecord, in db: Database, onlyWhileAccountExists accountId: Int64?) throws
    {
        // An upsert's `SELECT` needs a `WHERE` for SQLite to parse `ON CONFLICT` as the
        // upsert rather than a join constraint; the account check is that `WHERE`.
        try db.execute(
            sql: """
                INSERT INTO avatar (email, data, mime, isExternal, missing, fetchedAt)
                SELECT lower(:email), :data, :mime, :isExternal, :missing, :fetchedAt
                 WHERE :accountId IS NULL OR EXISTS (SELECT 1 FROM account WHERE id = :accountId)
                ON CONFLICT (email) DO UPDATE SET
                    data = excluded.data,
                    mime = excluded.mime,
                    isExternal = excluded.isExternal,
                    missing = excluded.missing,
                    fetchedAt = excluded.fetchedAt
                """,
            arguments: [
                "email": record.email,
                "data": record.data,
                "mime": record.mime,
                "isExternal": record.isExternal,
                "missing": record.missing,
                "fetchedAt": record.fetchedAt,
                "accountId": accountId,
            ]
        )
    }

    /// Deletes the avatar rows no message's sender and no contact's address names any more.
    ///
    /// `avatar` is shared across accounts (ADR-0033) and has no foreign key, so no cascade
    /// reaches it; this is what makes removing an account or a login take its correspondents
    /// with it. A contact's photo stays while any remaining contact has the address. `NOT IN`
    /// rather than a correlated `NOT EXISTS`, because each list is built once where the
    /// correlated form would scan per avatar row: nothing indexes `lower(fromEmail)`. The
    /// `IS NOT NULL` is load-bearing: `x NOT IN (…, NULL)` is never true, so one message
    /// without a sender would make this delete nothing.
    static func deleteUnreferencedAvatars(_ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM avatar
                 WHERE email NOT IN (SELECT lower(fromEmail) FROM message WHERE fromEmail IS NOT NULL)
                   AND email NOT IN (SELECT lower(email) FROM contactEmail)
                """
        )
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
