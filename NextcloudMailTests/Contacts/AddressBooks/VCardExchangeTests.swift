// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-36's vCard import (parsing, UID and href rules, one queued put per card), export (bytes
/// as stored, modulo folding) and the address-book writes, offline: no drainer runs.
@Suite("vCard import, export and address books")
@MainActor
struct VCardExchangeTests {
    private static let bookURL = "https://contacts.example.invalid/remote.php/dav/addressbooks/users/me/contacts/"
    private static let identity = ServerIdentity(serverURL: "https://contacts.example.invalid/", loginName: "me")

    private struct Fixture {
        let store: MailStore
        let queue: MutationQueue
        let actions: AddressBookActions
        let book: AddressBookRecord
        let loginId: Int64
    }

    private func fixture() async throws -> Fixture {
        let store = try MailStore.inMemory()
        let loginId = try #require(try await store.ensureLogin(Self.identity).id)
        _ = try await store.upsert(accounts: [
            AccountWrite(
                identity: Self.identity, remoteId: 1, name: "Me", emailAddress: "me@example.invalid", rawJSON: "{}")
        ])
        let books = try await store.syncAddressBooks(
            [AddressBookRecord(loginId: loginId, url: Self.bookURL, displayName: "Contacts")], loginId: loginId)
        let client = DAVClient(
            server: try #require(URL(string: "https://contacts.example.invalid/")),
            credentials: BasicCredentials(loginName: "me", appPassword: "x"))
        let queue = MutationQueue(
            store: store,
            configuration: MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: client)))
        return Fixture(
            store: store, queue: queue, actions: AddressBookActions(loginId: loginId, store: store, queue: queue),
            book: try #require(books.first), loginId: loginId)
    }

    /// A 3.0 card, a 4.0 card with no UID, a repeat of the first UID, and one whose UID is a URN.
    private static let mixedFile = [
        "BEGIN:VCARD", "VERSION:3.0", "UID:alpha", "FN:Alpha One", "N:One;Alpha;;;",
        "EMAIL;TYPE=INTERNET:alpha@example.org", "END:VCARD",
        "BEGIN:VCARD", "VERSION:4.0", "FN:Beta Two", "EMAIL;TYPE=work:beta@example.org", "END:VCARD",
        "BEGIN:VCARD", "VERSION:3.0", "UID:alpha", "FN:Alpha Again", "END:VCARD",
        "BEGIN:VCARD", "VERSION:4.0", "UID:urn:uuid:4fbe8971-0bc3-424c-9c26-36c3e1eff6b1", "FN:Gamma",
        "END:VCARD", "",
    ].joined(separator: "\r\n")

    @Test func importParsesEveryCardAndFixesUIDs() throws {
        var counter = 0
        let plan = try VCardImportPlan.make(
            data: Data(Self.mixedFile.utf8), bookURL: Self.bookURL, existing: []
        ) {
            counter += 1
            return "fresh-\(counter)"
        }
        #expect(plan.items.count == 4)
        #expect(
            plan.items.map { $0.card.uid } == [
                "alpha", "fresh-1", "fresh-2", "urn:uuid:4fbe8971-0bc3-424c-9c26-36c3e1eff6b1",
            ])
        #expect(plan.items.map(\.card.version) == ["3.0", "4.0", "3.0", "4.0"])
        let base = "/remote.php/dav/addressbooks/users/me/contacts/"
        #expect(
            plan.items.map(\.href) == [
                base + "alpha.vcf", base + "fresh-1.vcf", base + "fresh-2.vcf", base + "fresh-3.vcf",
            ])
        #expect(plan.newCount == 4 && plan.updateCount == 0)
    }

    @Test func aUIDAlreadyInTheBookUpdatesThatContact() throws {
        let existing = ContactRecord(
            id: 7, addressBookId: 1, href: "/remote.php/dav/addressbooks/users/me/contacts/somewhere.vcf",
            etag: "\"e1\"", uid: "alpha", vcard: "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:alpha\r\nFN:Old\r\nEND:VCARD\r\n",
            syncedAt: 0)
        let plan = try VCardImportPlan.make(
            data: Data(Self.mixedFile.utf8), bookURL: Self.bookURL, existing: [existing])
        #expect(plan.items[0].existing == existing)
        #expect(plan.items[0].href == existing.href)
        #expect(plan.updateCount == 1)
        let payload = VCardImportPlan.payload(plan.items[0], loginId: 1, addressBookId: 1)
        #expect(payload.etag == "\"e1\"")
        #expect(payload.before.existed)
        let fresh = VCardImportPlan.payload(plan.items[1], loginId: 1, addressBookId: 1)
        #expect(fresh.etag == nil && !fresh.before.existed)
    }

    @Test func emptyAndGarbageFilesAreRefused() {
        #expect(throws: VCardImportPlan.Failure.noCards) {
            try VCardImportPlan.make(data: Data(), bookURL: Self.bookURL, existing: [])
        }
        #expect(throws: VCardImportPlan.Failure.self) {
            try VCardImportPlan.make(
                data: Data("BEGIN:VCARD\r\nno colon here\r\nEND:VCARD\r\n".utf8), bookURL: Self.bookURL, existing: [])
        }
    }

    @Test func importQueuesOnePutPerCardAndLandsLocally() async throws {
        let f = try await fixture()
        var lines: [String] = []
        for index in 0..<120 {
            lines += ["BEGIN:VCARD", "VERSION:3.0", "UID:bulk-\(index)", "FN:Person \(index)", "END:VCARD"]
        }
        let plan = try VCardImportPlan.make(
            data: Data((lines + [""]).joined(separator: "\r\n").utf8), bookURL: f.book.url, existing: [])
        var reported: [Int] = []
        let started = ContinuousClock.now
        try await f.actions.importCards(plan, into: f.book) { reported.append($0) }
        let elapsed = ContinuousClock.now - started
        FileHandle.standardError.write(Data("  [measured] WS-36: 120 cards queued offline in \(elapsed)\n".utf8))
        #expect(reported == Array(1...120))
        let bookId = try #require(f.book.id)
        #expect(try await f.store.contacts(addressBookId: bookId).count == 120)
        let pending = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        #expect(pending.count == 120)
        #expect(Set(pending.map(\.kind)) == [.contactPut])
    }

    @Test func importRefusesAReadOnlyBook() async throws {
        let f = try await fixture()
        var readOnly = f.book
        readOnly.isReadOnly = true
        let plan = try VCardImportPlan.make(data: Data(Self.mixedFile.utf8), bookURL: f.book.url, existing: [])
        await #expect(throws: AddressBookActions.Failure.readOnly) {
            try await f.actions.importCards(plan, into: readOnly) { _ in }
        }
    }

    // MARK: - Export

    @Test func exportKeepsEveryLineAsStoredModuloFolding() throws {
        let long = String(repeating: "Long note text that the server folds. ", count: 6)
        // As sabre stores it: folded at 75 octets, with lines this app does not model.
        let unfolded = [
            "BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Sabre//Sabre VObject 4.5.6//EN", "UID:export-1",
            "FN:Export Person", "item1.EMAIL;TYPE=INTERNET:x@example.org", "item1.X-ABLabel:_$!<Other>!$_",
            "X-UNKNOWN;X-PARAM=\"kept, as is\":opaque\\;value", "NOTE:\(long)", "END:VCARD",
        ]
        let stored = unfolded.map(Self.fold).joined(separator: "\r\n") + "\r\n"
        let group = "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:group-1\r\nKIND:group\r\nFN:A group\r\nEND:VCARD\r\n"
        let records = [
            ContactRecord(addressBookId: 1, href: "/a.vcf", vcard: stored, syncedAt: 0),
            ContactRecord(addressBookId: 1, href: "/g.vcf", vcard: group, isGroup: true, syncedAt: 0),
        ]
        let exported = String(decoding: VCardExport.data(records), as: UTF8.self)
        let expected = unfolded.joined(separator: "\r\n") + "\r\n" + group
        #expect(exported.replacingOccurrences(of: "\r\n ", with: "") == expected)
        // And it reads back as the same two cards.
        #expect(try VCardParser.parse(exported).count == 2)
    }

    @Test func exportOfAnUnparsableCardIsTheStoredText() {
        let broken = "BEGIN:VCARD\nVERSION:3.0\nnot a content line\nEND:VCARD"
        let records = [ContactRecord(addressBookId: 1, href: "/b.vcf", vcard: broken, syncedAt: 0)]
        #expect(
            String(decoding: VCardExport.data(records), as: UTF8.self)
                == "BEGIN:VCARD\r\nVERSION:3.0\r\nnot a content line\r\nEND:VCARD\r\n")
    }

    @Test func exportFileName() {
        #expect(VCardExport.fileName("Work: 2026/Q4") == "Work- 2026-Q4.vcf")
        #expect(VCardExport.fileName(nil) == "Contacts.vcf")
    }

    private static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for character in line {
            let width = String(character).utf8.count
            if count + width > 75 {
                result += "\r\n "
                count = 1
            }
            result.append(character)
            count += width
        }
        return result
    }

    // MARK: - Address books

    @Test func newCollectionHrefSlugsAndNumbers() {
        let books = [
            AddressBookRecord(loginId: 1, url: Self.bookURL),
            AddressBookRecord(
                loginId: 1, url: "https://contacts.example.invalid/remote.php/dav/addressbooks/users/me/family/"),
        ]
        let home = "/remote.php/dav/addressbooks/users/me/"
        #expect(
            AddressBookActions.newCollectionHref(name: "Work Stuff!", books: books, fallbackHome: nil) == home
                + "work-stuff/")
        #expect(
            AddressBookActions.newCollectionHref(name: "Family", books: books, fallbackHome: nil) == home + "family-2/")
        #expect(
            AddressBookActions.newCollectionHref(name: "€€", books: books, fallbackHome: nil) == home + "addressbook/")
        #expect(AddressBookActions.newCollectionHref(name: "X", books: [], fallbackHome: nil) == nil)
        let fallback = AddressBookActions.fallbackHome(
            serverURL: URL(string: "https://cloud.example/nextcloud/")!, userId: "me")
        #expect(fallback == "/nextcloud/remote.php/dav/addressbooks/users/me/")
        #expect(AddressBookActions.newCollectionHref(name: "X", books: [], fallbackHome: fallback) == fallback + "x/")
    }

    @Test func principalsForUsersAndGroups() {
        #expect(
            AddressBookActions.principal(for: ShareeSuggestion(shareWith: "alice", type: "user", displayName: "Alice"))
                == "principal:principals/users/alice")
        #expect(
            AddressBookActions.principal(for: ShareeSuggestion(shareWith: "a team", type: "group", displayName: "A"))
                == "principal:principals/groups/a%20team")
    }

    @Test func bookWritesAreQueuedAndLocal() async throws {
        let f = try await fixture()
        let books = try await f.store.addressBooks(loginId: f.loginId)
        let href = try await f.actions.create(name: "Work", books: books, fallbackHome: nil)
        #expect(href == "/remote.php/dav/addressbooks/users/me/work/")
        var work = try #require(try await f.store.addressBooks(loginId: f.loginId).first { $0.url.hasSuffix("/work/") })
        #expect(work.displayName == "Work")

        try await f.actions.rename(work, to: "Office")
        work = try #require(try await f.store.addressBooks(loginId: f.loginId).first { $0.url == work.url })
        #expect(work.displayName == "Office")

        try await f.actions.setEnabled(false, book: work)
        work = try #require(try await f.store.addressBooks(loginId: f.loginId).first { $0.url == work.url })
        #expect(!work.isEnabled)

        try await f.actions.share(
            work, with: ShareeSuggestion(shareWith: "alice", type: "user", displayName: "Alice"), readOnly: true)
        try await f.actions.delete(work)
        #expect(try await f.store.addressBooks(loginId: f.loginId).allSatisfy { $0.url != work.url })

        let pending = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        // The delete absorbs what was queued for the same collection before it, except the
        // create, which it cancels out entirely, and the share, which is never folded.
        #expect(pending.contains { $0.kind == .addressBookShare && $0.payload.shareReadOnly == true })
        #expect(
            pending.first { $0.kind == .addressBookShare }?.payload.sharee == "principal:principals/users/alice")
    }

    @Test func sharedBooksRefuseOwnerOnlyWrites() async throws {
        let f = try await fixture()
        var shared = f.book
        shared.sharedBy = "principals/users/bob"
        await #expect(throws: AddressBookActions.Failure.notOwner) { try await f.actions.rename(shared, to: "Mine") }
        await #expect(throws: AddressBookActions.Failure.notOwner) { try await f.actions.delete(shared) }
    }

    @Test func mergeIsOnePutOverTheKeptCardAndOneDelete() async throws {
        let f = try await fixture()
        let file = [
            "BEGIN:VCARD", "VERSION:3.0", "UID:keep", "FN:Keep Me", "EMAIL:keep@example.org",
            "X-KEEP:unknown", "CATEGORIES:A", "END:VCARD",
            "BEGIN:VCARD", "VERSION:3.0", "UID:drop", "FN:Drop Me", "EMAIL:drop@example.org", "TITLE:Chief",
            "CATEGORIES:B", "END:VCARD", "",
        ].joined(separator: "\r\n")
        let plan = try VCardImportPlan.make(data: Data(file.utf8), bookURL: f.book.url, existing: [])
        try await f.actions.importCards(plan, into: f.book) { _ in }
        let bookId = try #require(f.book.id)
        let records = try await f.store.contacts(addressBookId: bookId)
        let kept = try #require(records.first { $0.uid == "keep" })
        let other = try #require(records.first { $0.uid == "drop" })
        let mergePlan = ContactMergePlan(
            kept: try #require(try VCardParser.parse(kept.vcard).first),
            other: try #require(try VCardParser.parse(other.vcard).first))
        try await f.actions.merge(mergePlan, kept: kept, other: other, books: [f.book])

        let after = try await f.store.contacts(addressBookId: bookId)
        #expect(after.map(\.uid) == ["keep"])
        let mergedRecord = try #require(after.first)
        let merged = try #require(try VCardParser.parse(mergedRecord.vcard).first)
        #expect(merged.emails.map(\.value) == ["keep@example.org", "drop@example.org"])
        #expect(merged.title == "Chief")
        #expect(merged.categories == ["A", "B"])
        #expect(merged.property("X-KEEP")?.rawValue == "unknown")
        // Neither card had been sent: the merge put folds into the kept card's create, and the
        // delete absorbs the other card's create — one put and one delete wait in the queue.
        let pending = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        #expect(pending.map(\.kind) == [.contactPut, .contactDelete])
        #expect(pending.first?.payload.body?.contains("TITLE:Chief") == true)
    }

    @Test func socialAutoUpdateIsDailyPerCard() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ContactsSocialAutoUpdate.isDue(uid: "a", stamps: [:], now: now))
        #expect(!ContactsSocialAutoUpdate.isDue(uid: "a", stamps: ["a": 1_000_000 - 3_600], now: now))
        #expect(ContactsSocialAutoUpdate.isDue(uid: "a", stamps: ["a": 1_000_000 - 86_400], now: now))
    }
}
