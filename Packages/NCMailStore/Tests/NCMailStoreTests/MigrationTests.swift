// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Migrations")
struct MigrationTests {
    /// The contract. If this fails, either `schema.sql` or `Migrations.swift` was changed
    /// without the other, and the failure names the object that diverged.
    @Test func schemaMatchesReference() async throws {
        let migrated = try await SchemaDump.ofDatabase(MailStore.inMemory())
        let reference = SchemaDump.ofSQL(try ReferenceSchema.load())

        #expect(Set(migrated.keys) == Set(reference.keys))
        for name in Set(migrated.keys).intersection(reference.keys).sorted() {
            #expect(migrated[name] == reference[name], "\(name) differs from docs/reference/schema.sql")
        }
    }

    /// The reference has to be worth comparing against. A normaliser that flattened everything
    /// to the empty string would pass the test above without noticing.
    @Test func referenceSchemaIsNotEmpty() throws {
        let reference = SchemaDump.ofSQL(try ReferenceSchema.load())
        #expect(reference.count == 28)
        #expect(reference["message"]?.contains("bodyState TEXT NOT NULL DEFAULT 'missing'") == true)
    }

    @Test func migratingAnAlreadyMigratedDatabaseChangesNothing() async throws {
        let store = try MailStore.inMemory()
        let before = try await SchemaDump.ofDatabase(store)
        try MailStoreMigrations.migrator.migrate(store.dbQueue)
        let after = try await SchemaDump.ofDatabase(store)
        #expect(before == after)
    }

    @Test func foreignKeysAreEnforced() async throws {
        let store = try MailStore.inMemory()
        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO mailbox (accountId, remoteId, name, displayName, rawJSON)
                        VALUES (999, 1, 'INBOX', 'INBOX', '{}')
                        """
                )
            }
        }
    }

    @Test func aFileBackedMirrorUsesWriteAheadLogging() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ncmailstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try MailStore(url: directory.appending(path: "mirror.sqlite"))
        let mode = try await store.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
        #expect(store.fileSizeOnDisk() > 0)
    }

    /// SQLite does not call `sqlite3_update_hook` for a WITHOUT ROWID table, and GRDB's
    /// `ValueObservation` is built on that hook, so an observation of such a table never fires —
    /// it just waits. Anything a view might watch has to have a rowid. `messageAddress` is the
    /// one exception, and it is not read by any query the UI runs. See ADR-0025.
    @Test func messageAddressIsTheOnlyTableWithoutARowid() async throws {
        let store = try MailStore.inMemory()
        let withoutRowid = try await store.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                     WHERE type = 'table' AND sql LIKE '%WITHOUT ROWID%'
                     ORDER BY name
                    """
            )
        }
        // FTS5 builds some of its own shadow tables WITHOUT ROWID. Nothing observes those
        // either, and they are not ours to choose.
        #expect(withoutRowid.filter { !SchemaDump.isGenerated($0) } == ["messageAddress"])
    }

    @Test func anInMemoryMirrorReportsNoFileSize() throws {
        #expect(try MailStore.inMemory().fileSizeOnDisk() == 0)
    }
}
