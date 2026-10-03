// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// The `login` row for one signed-in identity, created if it does not exist yet.
    ///
    /// Sync calls this before writing anything instance-scoped — address books, preferences,
    /// server flags — because those rows hang off the login (ADR-0079). The v2 migration
    /// backfills a row per identity already mirrored, so this inserts only for a login signed
    /// in after the upgrade, before its first account row lands.
    @discardableResult
    public func ensureLogin(_ identity: ServerIdentity) async throws -> LoginRecord {
        try await dbQueue.write { db in
            if let existing = try LoginRecord.fetchOne(
                db,
                sql: "SELECT * FROM login WHERE serverURL = ? AND loginName = ?",
                arguments: [identity.serverURL, identity.loginName]
            ) {
                return existing
            }
            var row = LoginRecord(identity: identity)
            try row.insert(db)
            return row
        }
    }

    public func login(for identity: ServerIdentity) async throws -> LoginRecord? {
        try await dbQueue.read { db in
            try LoginRecord.fetchOne(
                db,
                sql: "SELECT * FROM login WHERE serverURL = ? AND loginName = ?",
                arguments: [identity.serverURL, identity.loginName]
            )
        }
    }

    public func logins() async throws -> [LoginRecord] {
        try await dbQueue.read { db in
            try LoginRecord.fetchAll(db, sql: "SELECT * FROM login ORDER BY serverURL, loginName")
        }
    }

    /// One login's row, live — the instance flags gate UI (hide snooze, hide scheduled send),
    /// so the gates update the moment a sync discovers them.
    public func observeLogin(for identity: ServerIdentity) -> StoreObservation<LoginRecord?> {
        observation { db in
            try LoginRecord.fetchOne(
                db,
                sql: "SELECT * FROM login WHERE serverURL = ? AND loginName = ?",
                arguments: [identity.serverURL, identity.loginName]
            )
        }
    }

    /// Rewrites a login row — in practice: the instance flags a sync discovered.
    public func update(login: LoginRecord) async throws {
        try await dbQueue.write { db in try login.update(db) }
    }

    /// Signs one identity out of the mirror: its login row and its account rows, in one
    /// transaction.
    ///
    /// Two roots, deliberately. Everything instance-scoped cascades from `login`; everything
    /// mail-scoped cascades from `account`, whose rows carry the identity inline since v1 and
    /// do not reference `login` (ADR-0079). The FTS triggers take `messageSearch` and
    /// `contactSearch` rows with them. The caller is expected to `VACUUM` afterwards, same as
    /// ``deleteAccount(id:)``.
    public func deleteLogin(_ identity: ServerIdentity) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM account WHERE serverURL = ? AND loginName = ?",
                arguments: [identity.serverURL, identity.loginName]
            )
            try db.execute(
                sql: "DELETE FROM login WHERE serverURL = ? AND loginName = ?",
                arguments: [identity.serverURL, identity.loginName]
            )
        }
        storeLog.info("login removed from the mirror")
    }
}
