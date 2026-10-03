// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

extension MailStore {
    /// Reads a `meta` value: the sidebar's expansion state, the backfill pause flag, the
    /// cached theming colour. Anything that is app state and not worth a table.
    public func metaValue(forKey key: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    /// Writes a `meta` value, or removes it when `value` is nil.
    public func setMetaValue(_ value: String?, forKey key: String) async throws {
        try await dbQueue.write { db in
            if let value {
                try MetaRecord(key: key, value: value).upsert(db)
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }

    public func observeMetaValue(forKey key: String) -> StoreObservation<String?> {
        observation { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }
}
