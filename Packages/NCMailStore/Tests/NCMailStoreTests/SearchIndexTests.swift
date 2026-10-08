// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Search index maintenance")
struct SearchIndexTests {
    /// The invariant ADR-0011 rests on: a message row and its index row exist together or not
    /// at all. Every other test in this suite ends by asserting it.
    static func assertConsistent(_ store: MailStore, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (messages, indexed, orphans, unindexed) = try await store.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? -1,
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messageSearch") ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM messageSearch WHERE rowid NOT IN (SELECT id FROM message)"
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM message WHERE id NOT IN (SELECT rowid FROM messageSearch)"
                ) ?? -1
            )
        }
        #expect(messages == indexed, "message rows and index rows disagree", sourceLocation: sourceLocation)
        #expect(orphans == 0, "index rows with no message", sourceLocation: sourceLocation)
        #expect(unindexed == 0, "messages with no index row", sourceLocation: sourceLocation)
    }

    @Test func anEnvelopeIsSearchableAsSoonAsItIsWritten() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    subject: "Quarterly hedgehog census",
                    preview: "Numbers are up in the eastern hedgerow",
                    addresses: [EnvelopeAddress(kind: .from, email: "zoe@example.invalid", label: "Zoë Baker")]
                )
            ]
        )

        let hits = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch WHERE messageSearch MATCH 'hedgehog'")
        }
        #expect(hits == [1])
        try await Self.assertConsistent(store)
    }

    /// `remove_diacritics 2` is why this works, and it is the reason the tokeniser is spelled
    /// out in the schema rather than left at its default.
    @Test func theTokeniserIgnoresDiacritics() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    addresses: [EnvelopeAddress(kind: .from, email: "z@example.invalid", label: "Zoë")]
                )
            ]
        )
        let hits = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch WHERE messageSearch MATCH 'Zoe'")
        }
        #expect(hits == [1])
    }

    @Test func peopleIndexesFromToAndCcButNotBcc() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(
                    remoteId: 1,
                    sentAt: 100,
                    addresses: [
                        EnvelopeAddress(kind: .from, email: "ada@example.invalid", label: "Ada"),
                        EnvelopeAddress(kind: .to, email: "grace@example.invalid", label: "Grace"),
                        EnvelopeAddress(kind: .cc, email: "alan@example.invalid", label: "Alan"),
                        EnvelopeAddress(kind: .bcc, email: "katherine@example.invalid", label: "Katherine"),
                    ]
                )
            ]
        )
        let people = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT people FROM messageSearch WHERE rowid = 1") ?? ""
        }
        #expect(people.contains("Ada <ada@example.invalid>"))
        #expect(people.contains("Grace <grace@example.invalid>"))
        #expect(people.contains("Alan <alan@example.invalid>"))
        #expect(!people.contains("Katherine"))
    }

    /// The trap the two-step write exists to avoid: a flag change re-sends the envelope, and a
    /// naive delete-then-insert would silently drop the body from the index.
    @Test func reIndexingAnEnvelopeKeepsTheBodyText() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "Original")])
        try await store.upsert(
            body: MessageBodyWrite(fetchedAt: 200, plainBody: "pangolins and their habits"),
            for: 1
        )
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "Edited", isSeen: true)])

        let rows = try await store.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT subject || '|' || body FROM messageSearch WHERE rowid = 1"
            )
        }
        #expect(rows == ["Edited|pangolins and their habits"])
        try await Self.assertConsistent(store)
    }

    /// The converse: storing a body must not wipe the subject and people the envelope wrote.
    @Test func indexingABodyKeepsTheEnvelopeText() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "Marmots")])
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 200, plainBody: "burrows"), for: 1)

        let hits = try await store.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM messageSearch WHERE messageSearch MATCH 'Marmots AND burrows'"
            )
        }
        #expect(hits == [1])
    }

    @Test func markupIsStrippedBeforeIndexing() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "S")])
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 200,
                hasHtmlBody: true,
                html: "<div class=\"quote\"><p>Meet at the <b>observatory</b>&nbsp;at eight</p></div>"
            ),
            for: 1
        )
        let body = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM messageSearch WHERE rowid = 1") ?? ""
        }
        #expect(body.contains("observatory"))
        #expect(!body.contains("div"))
        #expect(!body.contains("class"))
    }

    @Test func deletingAMessageRemovesItsIndexRow() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...5).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })
        try await store.deleteMessages(ids: [2, 4])

        let remaining = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch ORDER BY rowid")
        }
        #expect(remaining == [1, 3, 5])
        try await Self.assertConsistent(store)
    }

    /// The server's sanitiser keeps `<style>`, and a marketing email is mostly CSS. Indexing it
    /// made the index three times the size of the mail and matched every such message on a
    /// search for `padding`.
    @Test func styleAndScriptContentsAreNotIndexed() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "S", preview: "P")])
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1,
                hasHtmlBody: true,
                html: """
                    <style type="text/css">
                    a:hover { color:#f1a7a5; padding:0; width:100% !important; }
                    </style>
                    <script>var tracking = "beacon";</script>
                    <p>Meet at the observatory at eight</p>
                    """
            ),
            for: 1
        )
        let body = try await store.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM messageSearch WHERE rowid = 1") ?? ""
        }
        #expect(body.contains("observatory"))
        #expect(!body.contains("padding"))
        #expect(!body.contains("f1a7a5"))
        #expect(!body.contains("beacon"))
    }

    /// A cascade is invisible to the Swift code that started it, which is why the delete half
    /// of the maintenance is a trigger rather than a call. Without it, signing out of an
    /// account would leave its subjects searchable.
    @Test func cascadingFromAMailboxRemovesIndexRows() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Archive")], accountId: 1)
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 1, mailboxId: 10, sentAt: 100),
                Seed.envelope(remoteId: 2, mailboxId: 11, sentAt: 200),
            ]
        )
        try await store.write { db in
            try db.execute(sql: "DELETE FROM mailbox WHERE id = 11")
        }
        let remaining = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch")
        }
        #expect(remaining == [1])
        try await Self.assertConsistent(store)
    }

    @Test func removingLocalCopiesEmptiesBodiesAndLeavesEnvelopesSearchable() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100, subject: "Ospreys")])
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 200, plainBody: "nesting platform"), for: 1)

        try await store.removeLocalCopies(accountId: 1, resetBodyState: true)

        let bySubject = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch WHERE messageSearch MATCH 'Ospreys'")
        }
        let byBody = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messageSearch WHERE messageSearch MATCH 'nesting'")
        }
        let state = try await store.message(id: 1)?.bodyState
        #expect(bySubject == [1])
        #expect(byBody.isEmpty)
        #expect(state == .missing)
        #expect(try await store.body(messageId: 1) == nil)
        try await Self.assertConsistent(store)
    }

    /// Writes on a `DatabaseQueue` are serialised, so this does not test SQLite's locking. It
    /// tests that no code path here leaves the index half-written when a hundred unrelated
    /// writes interleave with each other — which is what a backfill and a triage action do.
    @Test func theIndexSurvivesConcurrentWriters() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...200).map { Seed.envelope(remoteId: $0, sentAt: 1000 + $0) })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in Int64(1)...200 {
                group.addTask {
                    switch id % 4 {
                    case 0:
                        try await store.deleteMessages(ids: [id])
                    case 1:
                        try await store.upsert(
                            body: MessageBodyWrite(fetchedAt: 1, plainBody: "body \(id)"),
                            for: id
                        )
                    case 2:
                        try await store.upsert(
                            envelopes: [Seed.envelope(remoteId: id, sentAt: 1000 + id, subject: "again \(id)")]
                        )
                    default:
                        try await store.upsert(
                            envelopes: [Seed.envelope(remoteId: 1000 + id, sentAt: 2000 + id, subject: "new \(id)")]
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        try await Self.assertConsistent(store)
        let deleted = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE id % 4 = 0 AND id <= 200") ?? -1
        }
        #expect(deleted == 0)
    }

    // MARK: - Removed text leaves the file

    /// The two controls that promise the user their mail's text is gone from this Mac.
    enum Removal: String, CaseIterable, Sendable {
        case deleteAccount
        case removeLocalCopies
    }

    /// A plain FTS5 delete only appends a marker that cancels the posting at query time; the
    /// posting itself stays in `messageSearch_data` until a merge happens to combine the two,
    /// and `VACUUM` copies it faithfully into the new file. Searching returned nothing while
    /// the words were still readable in the bytes.
    ///
    /// The words are checked minus their first letter too, because FTS5 stores a term as the
    /// suffix it does not share with the term before it on the page.
    @Test(arguments: Removal.allCases)
    func removedTextLeavesNoBytesInTheFile(_ removal: Removal) async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "mirror.sqlite")
        let store = try MailStore(url: url)
        try await Seed.base(store)
        let kept = try #require(try await store.upsert(accounts: [Seed.account(remoteId: 2)]).first)
        let inbox = MailboxWrite(
            accountId: kept.id,
            remoteId: 5,
            name: "INBOX",
            displayName: "INBOX",
            isSubscribed: true
        )
        let keptMailbox = try #require(try await store.upsert(mailboxes: [inbox], accountId: kept.id).first)

        // One transaction per message, alternating accounts, the way a backfill commits: the
        // index ends up in many segments, and a removal's delete markers land in new ones.
        for remoteId in Int64(1)...200 {
            let removed = remoteId % 2 == 1
            let secret = remoteId == 101
            let envelope = Seed.envelope(
                remoteId: remoteId,
                mailboxId: removed ? 10 : keptMailbox.id,
                accountId: removed ? 1 : kept.id,
                sentAt: 1000 + remoteId,
                subject: secret ? "xylophonevault board minutes" : "routine minutes \(remoteId)"
            )
            let id = try #require(try await store.upsert(envelopes: [envelope]).first)
            let text = secret ? "the code word is quokkamarmalade" : "routine body \(remoteId)"
            try await store.upsert(body: MessageBodyWrite(fetchedAt: 1, plainBody: text), for: id)
        }

        var gone = ["quokkamarmalade", "uokkamarmalade"]
        let stillSearchable: Int
        switch removal {
        case .deleteAccount:
            try await store.deleteAccount(id: 1)
            gone += ["xylophonevault", "ylophonevault"]
            stillSearchable = 100
        case .removeLocalCopies:
            // Envelopes stay, so the subject stays; only the body has to go.
            try await store.removeLocalCopies(accountId: 1, resetBodyState: true)
            stillSearchable = 199
        }
        try await store.vacuum()

        let bytes = try Self.bytesOnDisk(url)
        for word in gone {
            #expect(bytes.range(of: Data(word.utf8)) == nil, "'\(word)' is still in the file")
        }
        // Purged, not dropped: what was not removed is still found.
        let routine = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messageSearch WHERE messageSearch MATCH 'routine'")
        }
        #expect(routine == stillSearchable)
        try await Self.assertConsistent(store)
    }

    /// Signing a login out removes its contacts, and `contactSearch` holds their names and
    /// addresses the same way `messageSearch` holds mail: a delete marker, and the posting
    /// left in the file.
    @Test func removedContactsLeaveNoBytesInTheFile() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "mirror.sqlite")
        let store = try MailStore(url: url)
        let loginId = try #require(try await store.ensureLogin(Seed.identity).id)
        let book = try #require(
            try await store.syncAddressBooks(
                [AddressBookRecord(loginId: loginId, url: "/dav/books/personal/", displayName: "Personal")],
                loginId: loginId
            ).first?.id
        )
        // One transaction per card, so the index is in several segments.
        for number in 1...50 {
            let secret = number == 25
            try await store.upsert(
                contact: ContactRecord(
                    addressBookId: book,
                    href: "/dav/books/personal/\(number).vcf",
                    vcard: "BEGIN:VCARD\nEND:VCARD",
                    displayName: secret ? "Zanzibarquince Holloway" : "Routine Person \(number)",
                    syncedAt: 1
                ),
                emails: [
                    ContactEmailRecord(
                        contactId: 0,
                        position: 0,
                        email: secret ? "zanzibarquince@example.invalid" : "p\(number)@example.invalid"
                    )
                ]
            )
        }

        try await store.deleteLogin(Seed.identity)
        try await store.vacuum()

        let bytes = try Self.bytesOnDisk(url)
        for word in ["zanzibarquince", "anzibarquince"] {
            #expect(bytes.range(of: Data(word.utf8)) == nil, "'\(word)' is still in the file")
        }
    }

    /// A mirror that had mail removed before `vacuum()` rebuilt the index still holds the
    /// postings those removals left, in live index segments that the removal's own `VACUUM`
    /// copied over. Opening it once must purge them, from the index and from the pages the
    /// purge frees, without waiting for the next removal.
    @Test func upgradingAMirrorPurgesWhatEarlierRemovalsLeft() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "mirror.sqlite")

        var configuration = Configuration()
        configuration.journalMode = .wal
        let v1 = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        try MailStoreMigrations.migrator.migrate(v1, upTo: "v1")
        for rowid in Int64(1)...200 {
            let body = rowid == 101 ? "the code word is quokkamarmalade" : "routine body \(rowid)"
            try await v1.write { db in
                try db.execute(
                    sql: "INSERT INTO messageSearch(rowid, subject, preview, body, people) VALUES (?, '', '', ?, '')",
                    arguments: [rowid, body]
                )
            }
        }
        // What a removal did before this version: delete, then `VACUUM`.
        try await v1.write { db in try db.execute(sql: "DELETE FROM messageSearch WHERE rowid = 101") }
        try await v1.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let leftBehind = try await v1.read { db in try Self.postingBlocks(containing: "uokkamarmalade", in: db) }
        try #require(leftBehind > 0, "the v1 delete purged the posting itself, so there is nothing to test")
        try #require(try Self.bytesOnDisk(url).range(of: Data("uokkamarmalade".utf8)) != nil)
        try v1.close()

        let store = try MailStore(url: url)
        let afterUpgrade = try await store.read { db in try Self.postingBlocks(containing: "uokkamarmalade", in: db) }
        #expect(afterUpgrade == 0)
        try await store.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        #expect(try Self.bytesOnDisk(url).range(of: Data("uokkamarmalade".utf8)) == nil)
    }

    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ncmailstore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The database file and its write-ahead log, which is where a reader of the container
    /// would look.
    private static func bytesOnDisk(_ url: URL) throws -> Data {
        try ["", "-wal"].reduce(into: Data()) { bytes, suffix in
            let file = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
            bytes.append(try Data(contentsOf: file))
        }
    }

    private static func postingBlocks(containing term: String, in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messageSearch_data WHERE instr(block, CAST(? AS BLOB)) > 0",
            arguments: [term]
        ) ?? -1
    }
}
