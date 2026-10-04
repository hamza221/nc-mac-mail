// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

@Suite("ContactsSync against recorded CardDAV answers")
struct ContactsSyncTests {
    private static let contactsReport: RequestMatcher =
        .report && .pathContains("/users/user/contacts") && .bodyContains("sync-collection")
    private static let multiget: RequestMatcher = .report && .bodyContains("addressbook-multiget")
    private static let alice = "/remote.php/dav/addressbooks/users/user/contacts/ws17-alice.vcf"

    @Test func listingMirrorsEnabledReadOnlyAndSharedBy() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        try await harness.stubOtherBooksEmpty()

        let report = try await harness.sync().runPass()

        let books = try await harness.store.addressBooks(loginId: harness.loginId)
        #expect(report.booksListed == books.count)
        let contacts = try #require(books.first { $0.url.hasSuffix("/users/user/contacts/") })
        #expect(contacts.isEnabled && !contacts.isReadOnly && contacts.sharedBy == nil)
        let disabled = try #require(books.first { $0.url.hasSuffix("/ws24-temp-disabled/") })
        #expect(!disabled.isEnabled)
        let system = try #require(books.first { $0.url.hasSuffix("/z-server-generated--system/") })
        #expect(system.isReadOnly)
        #expect(system.sharedBy == "principals/system/system")
        let recent = try #require(books.first { $0.url.contains("contactsinteraction") })
        #expect(recent.isReadOnly && recent.sharedBy == nil)
        // Every book got its round; all but the token-less one have a token now.
        #expect(books.allSatisfy { $0.lastSyncAt != nil })
        #expect(books.filter { $0.syncToken == nil }.map(\.url) == [recent.url])
    }

    @Test func initialRoundWritesCardsEmailsAndContactPhotos() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stub(Self.contactsReport, with: try .fixture("dav-sync-initial.xml", status: 207))
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-addressbook-multiget.xml", status: 207))
        try await harness.stubOtherBooksEmpty()

        let report = try await harness.sync().runPass()

        let book = try await harness.book()
        #expect(book.syncToken == "http://sabre.io/ns/sync/61")
        let cards = try await harness.store.contacts(addressBookId: try #require(book.id))
        #expect(cards.count == 2)
        #expect(report.cardsWritten == 2)
        // Four changed hrefs, one multiget: well under the batch of 100.
        #expect(report.multigetRequests == 1)
        let alice = try #require(cards.first { $0.href == Self.alice })
        #expect(alice.etag != nil)
        #expect(alice.vcard.contains("BEGIN:VCARD"))
        let emails = try await harness.store.contactEmails(contactId: try #require(alice.id))
        #expect(!emails.isEmpty)

        // Alice's inline PNG is her avatar for every address, ahead of any server answer.
        let avatar = try #require(try await harness.store.avatar(for: emails[0].email))
        #expect(avatar.data != nil && !avatar.isExternal && !avatar.missing)
    }

    @Test func unchangedTokenSkipsTheBookWithoutAReport() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        try await harness.stubOtherBooksEmpty()
        let sync = harness.sync()
        _ = try await sync.runPass()
        // Stamp the listed token, as a completed round against that state would have.
        let home = try #require(URL(string: "https://cloud.example.com/remote.php/dav/addressbooks/users/user/"))
        let listing = AddressBookListing.parse(
            try await harness.client.propfind(home, depth: .one, properties: AddressBookListing.properties),
            client: harness.client, ownPrincipalPath: nil)
        for book in try await harness.store.addressBooks(loginId: harness.loginId) {
            let listed = try #require(listing.first { $0.url == book.url })
            try await harness.store.setAddressBookSyncToken(
                listed.syncToken, lastSyncAt: 1, addressBookId: try #require(book.id))
        }
        let reportsBefore = await harness.transport.requests.filter { $0.httpMethod == "REPORT" }.count

        let report = try await sync.runPass()

        let reportsAfter = await harness.transport.requests.filter { $0.httpMethod == "REPORT" }.count
        // Only the token-less "Recently contacted" book is visited, by ETag listing.
        #expect(report.booksSynced == 1)
        #expect(reportsAfter == reportsBefore)
    }

    @Test func aBookWithoutSyncCollectionIsMirroredByETagListing() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stub(
            .propfind && .pathContains("contactsinteraction"),
            with: try .fixture("dav-ws24-merge-etags.xml", status: 207))
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-ws24-merge-base.xml", status: 207))
        try await harness.stubOtherBooksEmpty()
        let recentURL =
            "https://cloud.example.com/remote.php/dav/addressbooks/users/user/z-app-generated--contactsinteraction--recent/"

        _ = try await harness.sync().runPass()

        let book = try await harness.book(recentURL)
        let cards = try await harness.store.contacts(addressBookId: try #require(book.id))
        #expect(cards.map(\.href) == ["/remote.php/dav/addressbooks/users/user/ws24-temp-merge/ws24-merge.vcf"])
        #expect(book.syncToken == nil && book.lastSyncAt != nil)
        // No sync-collection REPORT went to it: the server answers those with 415.
        let reports = await harness.transport.requests.filter {
            $0.httpMethod == "REPORT" && ($0.url?.path.contains("contactsinteraction") ?? false)
                && String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("sync-collection")
        }
        #expect(reports.isEmpty)
    }

    @Test func incrementalRoundDeletesWhatTheServerRemoved() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stubSequence(
            Self.contactsReport,
            [try .fixture("dav-sync-initial.xml", status: 207), try .fixture("dav-sync-incremental.xml", status: 207)])
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-addressbook-multiget.xml", status: 207))
        try await harness.stubOtherBooksEmpty()
        let sync = harness.sync()
        _ = try await sync.runPass()
        let bookId = try #require(try await harness.book().id)
        // The card the incremental answer reports as removed, mirrored earlier.
        let removedHref = "/remote.php/dav/addressbooks/users/user/contacts/ws19-temp-removed.vcf"
        let text = try await ContactsHarness.cardText(fixture: "dav-ws24-merge-base.xml").text
        let row = try #require(
            ContactMapping.row(vcard: text, href: removedHref, etag: "\"x\"", addressBookId: bookId, syncedAt: 1))
        try await harness.store.upsert(contact: row.record, emails: row.emails)

        let report = try await sync.runPass()

        #expect(report.cardsDeleted == 1)
        let hrefs = try await harness.store.contacts(addressBookId: bookId).map(\.href)
        #expect(!hrefs.contains(removedHref))
        #expect(try await harness.book().syncToken == "http://sabre.io/ns/sync/63")
    }

    @Test func truncatedAnswerLoopsWithTheNewToken() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stubSequence(
            Self.contactsReport,
            [try .fixture("dav-sync-truncated.xml", status: 207), try .fixture("dav-sync-initial.xml", status: 207)])
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-addressbook-multiget.xml", status: 207))
        try await harness.stubOtherBooksEmpty()

        _ = try await harness.sync().runPass()

        let reports = await harness.transport.requests.filter { Self.contactsReport.matches($0) }
        #expect(reports.count == 2)
        let second = String(decoding: try #require(reports.last?.httpBody), as: UTF8.self)
        #expect(second.contains("init_126_63"))
        #expect(try await harness.book().syncToken == "http://sabre.io/ns/sync/61")
    }

    @Test func refusedTokenStartsOverAndDropsLeftovers() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stubSequence(
            Self.contactsReport,
            [
                try .fixture("dav-sync-empty.xml", status: 207),
                try .fixture("dav-error-invalid-sync-token.xml", status: 403),
                try .fixture("dav-sync-initial.xml", status: 207),
            ])
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-addressbook-multiget.xml", status: 207))
        try await harness.stubOtherBooksEmpty()
        let sync = harness.sync()
        _ = try await sync.runPass()
        let bookId = try #require(try await harness.book().id)
        try await harness.store.setAddressBookSyncToken("ws24-not-a-token", lastSyncAt: 1, addressBookId: bookId)
        let leftover = "/remote.php/dav/addressbooks/users/user/contacts/gone.vcf"
        let text = try await ContactsHarness.cardText(fixture: "dav-ws24-merge-base.xml").text
        let row = try #require(
            ContactMapping.row(vcard: text, href: leftover, etag: "\"x\"", addressBookId: bookId, syncedAt: 1))
        try await harness.store.upsert(contact: row.record)

        _ = try await sync.runPass()

        let hrefs = try await harness.store.contacts(addressBookId: bookId).map(\.href)
        #expect(!hrefs.contains(leftover))
        #expect(hrefs.contains(Self.alice))
        #expect(try await harness.book().syncToken == "http://sabre.io/ns/sync/61")
    }

    @Test func aCardWithAQueuedWriteIsNotOverwritten() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stub(Self.contactsReport, with: try .fixture("dav-sync-initial.xml", status: 207))
        await harness.transport.stub(Self.multiget, with: try .fixture("dav-addressbook-multiget.xml", status: 207))
        try await harness.stubOtherBooksEmpty()
        let pending = DAVWrite(
            operationId: 1, kind: .contactPut, accountId: 1,
            payload: DAVWritePayload(loginId: harness.loginId, href: Self.alice, body: "BEGIN:VCARD\r\nEND:VCARD\r\n"))

        let report = try await harness.sync(pending: [pending]).runPass()

        #expect(report.cardsHeldForPendingWrites == 1)
        let cards = try await harness.store.contacts(addressBookId: try #require(try await harness.book().id))
        #expect(!cards.contains { $0.href == Self.alice })
        // The multiget never asked for it either.
        let bodies = await harness.transport.requests.filter { Self.multiget.matches($0) }
            .compactMap(\.httpBody).map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.allSatisfy { !$0.contains("ws17-alice.vcf") })
    }

    @Test func serverEnabledToggleWinsUnlessAnUpdateIsQueued() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        try await harness.stubOtherBooksEmpty()
        _ = try await harness.sync().runPass()
        let bookId = try #require(try await harness.book().id)

        try await harness.store.setAddressBookEnabled(false, addressBookId: bookId)
        _ = try await harness.sync().runPass()
        #expect(try await harness.book().isEnabled)

        try await harness.store.setAddressBookEnabled(false, addressBookId: bookId)
        let queued = DAVWrite(
            operationId: 2, kind: .addressBookUpdate, accountId: 1,
            payload: DAVWritePayload(loginId: harness.loginId, addressBookId: bookId, enabled: false))
        _ = try await harness.sync(pending: [queued]).runPass()
        #expect(try await harness.book().isEnabled == false)
    }

    @Test func offlineTouchesNothing() async throws {
        let harness = try await ContactsHarness()
        let sync = harness.sync()
        await sync.apply(conditions: MirrorConditions(isOffline: true))

        let report = await sync.syncNow()

        #expect(report == ContactsSyncReport())
        #expect(await harness.transport.sendCount == 0)
    }
}
