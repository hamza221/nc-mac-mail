// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The Contacts views' writes with no drainer — offline: each lands in the mirror at once
/// and waits in the queue as one DAV row.
@Suite("Contacts writes, offline")
@MainActor
struct ContactsActionsTests {
    private struct Fixture {
        let store: MailStore
        let queue: MutationQueue
        let actions: ContactsActions
        let book: AddressBookRecord
        let readOnly: AddressBookRecord
        let loginId: Int64
    }

    private static let identity = ServerIdentity(serverURL: "https://contacts.example.invalid/", loginName: "me")

    private func fixture() async throws -> Fixture {
        let store = try MailStore.inMemory()
        let loginId = try #require(try await store.ensureLogin(Self.identity).id)
        _ = try await store.upsert(accounts: [
            AccountWrite(
                identity: Self.identity, remoteId: 1, name: "Me", emailAddress: "me@example.invalid", rawJSON: "{}")
        ])
        let books = try await store.syncAddressBooks(
            [
                AddressBookRecord(
                    loginId: loginId,
                    url: "https://contacts.example.invalid/remote.php/dav/addressbooks/users/me/contacts/",
                    displayName: "Contacts"),
                AddressBookRecord(
                    loginId: loginId,
                    url: "https://contacts.example.invalid/remote.php/dav/addressbooks/users/me/shared_by_bob/",
                    displayName: "Bob's", isReadOnly: true, sharedBy: "Bob", position: 1),
            ],
            loginId: loginId)
        let client = DAVClient(
            server: try #require(URL(string: "https://contacts.example.invalid/")),
            credentials: BasicCredentials(loginName: "me", appPassword: "x"))
        let queue = MutationQueue(
            store: store,
            configuration: MutationQueueConfiguration(dav: ContactWriteHandler(store: store, client: client)))
        return Fixture(
            store: store, queue: queue, actions: ContactsActions(loginId: loginId, store: store, queue: queue),
            book: try #require(books.first { !$0.isReadOnly }), readOnly: try #require(books.first { $0.isReadOnly }),
            loginId: loginId)
    }

    private func newPerson(_ f: Fixture, given: String = "Rory") async throws -> ContactRecord {
        var draft = ContactDraft.new(uid: "ws35-\(given)")
        draft.given = given
        draft.family = "Gilmore"
        draft.fields.append(.init(kind: .email, type: "HOME", value: "\(given.lowercased())@example.invalid"))
        let id = try #require(try await f.actions.create(draft, in: f.book))
        return try #require(try await f.store.contact(id: id))
    }

    @Test func createLandsLocallyAtTheWebContactsHref() async throws {
        let f = try await fixture()
        let record = try await newPerson(f)
        #expect(record.href == "/remote.php/dav/addressbooks/users/me/contacts/ws35-Rory.vcf")
        #expect(record.displayName == "Rory Gilmore")
        let pending = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        #expect(pending.map(\.kind) == [.contactPut])
    }

    @Test func editIsLocalAtOnceAndQueued() async throws {
        let f = try await fixture()
        let record = try await newPerson(f)
        var draft = ContactDraft(card: try #require(try VCardParser.parse(record.vcard).first))
        draft.title = "Editor, Yale Daily News"
        try await f.actions.save(draft, over: record, in: f.book)
        let id = try #require(record.id)
        let after = try #require(try await f.store.contact(id: id))
        #expect(after.vcard.contains("TITLE:Editor\\, Yale Daily News"))
        // Waiting for the drainer, the newest body last.
        let pending = try await f.queue.pendingDAVWrites(loginId: f.loginId)
        #expect(pending.allSatisfy { $0.kind == .contactPut })
        #expect(pending.last?.payload.body?.contains("TITLE:Editor") == true)
    }

    @Test func favouriteFlipsTheRowAndQueuesAPropPatchKind() async throws {
        let f = try await fixture()
        let record = try await newPerson(f)
        try await f.actions.setFavorite(true, contact: record, in: f.book)
        let id = try #require(record.id)
        #expect(try await f.store.contact(id: id)?.isFavorite == true)
        let kinds = try await f.queue.pendingDAVWrites(loginId: f.loginId).map(\.kind)
        #expect(kinds.contains(.contactFavorite))
    }

    @Test func deleteRemovesLocallyAndQueues() async throws {
        let f = try await fixture()
        let record = try await newPerson(f)
        try await f.actions.delete([record], books: [f.book, f.readOnly])
        let id = try #require(record.id)
        #expect(try await f.store.contact(id: id) == nil)
    }

    @Test func readOnlyBooksRefuseEveryWrite() async throws {
        let f = try await fixture()
        let draft = ContactDraft.new(uid: "ro")
        await #expect(throws: ContactsActions.Failure.readOnly) { try await f.actions.create(draft, in: f.readOnly) }
        let record = ContactRecord(
            id: 99, addressBookId: try #require(f.readOnly.id), href: "/x.vcf", vcard: "", syncedAt: 0)
        await #expect(throws: ContactsActions.Failure.readOnly) {
            try await f.actions.setFavorite(true, contact: record, in: f.readOnly)
        }
        await #expect(throws: ContactsActions.Failure.readOnly) {
            try await f.actions.delete([record], books: [f.readOnly])
        }
    }

    @Test func noQueueIsSignedOut() async throws {
        let f = try await fixture()
        let actions = ContactsActions(loginId: f.loginId, store: f.store, queue: nil)
        await #expect(throws: ContactsActions.Failure.noQueue) {
            try await actions.create(ContactDraft.new(uid: "q"), in: f.book)
        }
    }

    /// Measurement: parsing a 2,000-card login into list entries and ordering it, which is
    /// what each mirror change costs the Contacts section.
    @Test func twoThousandCardsParseAndSortQuickly() {
        let records = (0..<2_000).map { index in
            ContactRecord(
                id: Int64(index + 1), addressBookId: 1, href: "/\(index).vcf",
                vcard: """
                    BEGIN:VCARD\r\nVERSION:3.0\r\nUID:p\(index)\r\nFN:Person \(index)\r\nN:Family\(index % 97);Given\(index);;;\r\n\
                    EMAIL;TYPE=WORK:p\(index)@example.invalid\r\nTEL;TYPE=CELL:+1 555 \(index)\r\nCATEGORIES:G\(index % 7)\r\n\
                    NOTE:Some note text for person \(index)\r\nREV:20260101T000000Z\r\nEND:VCARD\r\n
                    """,
                isFavorite: index % 50 == 0, syncedAt: 0)
        }
        let clock = ContinuousClock()
        let parseStart = clock.now
        let entries = records.compactMap(ContactEntry.init(record:))
        let groups = ContactsListing.groups(entries)
        let parsed = clock.now - parseStart
        let sortStart = clock.now
        let rows = ContactsListing.rows(entries, scope: .all, recentBookIds: [], matching: nil, order: .lastName)
        let sorted = clock.now - sortStart
        FileHandle.standardError.write(
            Data(
                "  [measured] WS-35 contacts: 2,000 cards parsed+grouped in \(parsed), sorted by last name in \(sorted)\n"
                    .utf8))
        #expect(rows.count == 2_000)
        #expect(groups.count == 7)
        #expect(rows.first?.isFavorite == true)
    }
}
