// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// WS-35: web Contacts' favourite (`nc:favorite`, ADR-0092) and the social-avatar request,
/// on the recorded `dav-ws35-*` answers of scratch book `ws35-temp-fav`.
@Suite("Contact favourites and social avatars")
struct ContactFavoriteTests {
    private static let favHref = "/remote.php/dav/addressbooks/users/user/ws35-temp-fav/ws35-fav.vcf"
    private static let socialHref = "/remote.php/dav/addressbooks/users/user/ws35-temp-fav/ws35-social.vcf"
    private static let recentURL =
        "https://cloud.example.com/remote.php/dav/addressbooks/users/user/z-app-generated--contactsinteraction--recent/"

    /// The two recorded cards, written into `bookId` as the mirror would hold them, not favourites.
    private func seedCards(_ harness: ContactsHarness, bookId: Int64) async throws -> (fav: Int64, social: Int64) {
        await harness.transport.stub(.report, with: try .fixture("dav-ws35-multiget-favorite.xml", status: 207))
        let resources = try await harness.client.addressbookMultiget(
            try #require(URL(string: ContactsHarness.contactsBook)), hrefs: [Self.favHref])
        var ids: [String: Int64] = [:]
        for resource in resources {
            let vcard = try #require(resource.addressData)
            let row = try #require(
                ContactMapping.row(
                    vcard: vcard, href: resource.href, etag: resource.etag, addressBookId: bookId, syncedAt: 1))
            let written = try await harness.store.upsert(contact: row.record)
            let id: Int64 = try #require(written.id)
            ids[resource.href] = id
        }
        return (try #require(ids[Self.favHref]), try #require(ids[Self.socialHref]))
    }

    /// A first pass, then every token book stamped with its listed token — the state after a
    /// completed round, so the next pass sends no `sync-collection` at all.
    private func settle(_ harness: ContactsHarness, _ sync: ContactsSync) async throws {
        _ = try await sync.runPass()
        let home = try #require(URL(string: "https://cloud.example.com" + ContactsHarness.home))
        let listing = AddressBookListing.parse(
            try await harness.client.propfind(home, depth: .one, properties: AddressBookListing.properties),
            client: harness.client, ownPrincipalPath: nil)
        for book in try await harness.store.addressBooks(loginId: harness.loginId) {
            let listed = try #require(listing.first { $0.url == book.url })
            try await harness.store.setAddressBookSyncToken(
                listed.syncToken, lastSyncAt: 1, addressBookId: try #require(book.id))
        }
    }

    private static let contactsFavorites: RequestMatcher =
        .propfind && .pathContains("/users/user/contacts") && .bodyContains("nc:favorite")

    // MARK: - Sync

    /// The measured case: the toggle moved neither the token nor the ETag, so only the
    /// per-pass listing can see it — and it does, with no sync-collection sent.
    @Test func aFavouriteToggledElsewhereLandsThoughTheTokenDidNotMove() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stubSequence(
            Self.contactsFavorites,
            [try .fixture("dav-sync-empty.xml", status: 207), try .fixture("dav-ws35-favorites.xml", status: 207)])
        try await harness.stubOtherBooksEmpty()
        let sync = harness.sync()
        try await settle(harness, sync)
        let bookId = try #require(try await harness.book().id)
        let ids = try await seedCards(harness, bookId: bookId)
        let reportsBefore = await harness.transport.requests.filter { $0.httpMethod == "REPORT" }.count

        let report = try await sync.runPass()

        #expect(try await harness.store.contact(id: ids.fav)?.isFavorite == true)
        #expect(try await harness.store.contact(id: ids.social)?.isFavorite == false)
        #expect(report.favoritesChanged == 1)
        #expect(report.favoriteListings >= 1)
        // seedCards' own multiget is the only REPORT since: no sync-collection went out.
        let reportsAfter = await harness.transport.requests.filter { $0.httpMethod == "REPORT" }.count
        #expect(reportsAfter == reportsBefore)
    }

    @Test func aQueuedToggleKeepsTheLocalFlagAgainstTheListing() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stubSequence(
            Self.contactsFavorites,
            [try .fixture("dav-sync-empty.xml", status: 207), try .fixture("dav-ws35-favorites.xml", status: 207)])
        try await harness.stubOtherBooksEmpty()
        try await settle(harness, harness.sync())
        let bookId = try #require(try await harness.book().id)
        let ids = try await seedCards(harness, bookId: bookId)
        let card = try #require(try await harness.store.contact(id: ids.fav))
        // The user unfavourited it offline; the server still says "1".
        let pending = DAVWrite(
            operationId: 1, kind: .contactFavorite, accountId: 1,
            payload: ContactWriteHandler.favoritePayload(loginId: harness.loginId, contact: card, favorite: false))

        _ = try await harness.sync(pending: [pending]).runPass()

        #expect(try await harness.store.contact(id: ids.fav)?.isFavorite == false)
    }

    /// A token-less book's ETag listing asks for `nc:favorite` too, and the multiget that
    /// fills it carries the flag: new cards arrive already starred.
    @Test func aListedBookArrivesWithItsFavourites() async throws {
        let harness = try await ContactsHarness()
        try await harness.stubDiscoveryAndListing()
        await harness.transport.stub(
            .propfind && .pathContains("contactsinteraction"),
            with: try .fixture("dav-ws35-favorites.xml", status: 207))
        await harness.transport.stub(
            .report && .bodyContains("addressbook-multiget"),
            with: try .fixture("dav-ws35-multiget-favorite.xml", status: 207))
        try await harness.stubOtherBooksEmpty()

        _ = try await harness.sync().runPass()

        let book = try await harness.book(Self.recentURL)
        let cards = try await harness.store.contacts(addressBookId: try #require(book.id))
        #expect(cards.first { $0.href == Self.favHref }?.isFavorite == true)
        #expect(cards.first { $0.href == Self.socialHref }?.isFavorite == false)
        let listing = try #require(
            await harness.transport.requests.first { $0.url?.path.contains("contactsinteraction") ?? false })
        #expect(String(decoding: listing.httpBody ?? Data(), as: UTF8.self).contains("<nc:favorite/>"))
    }

    // MARK: - Handler

    private func handlerSetup() async throws -> (ContactsHarness, ContactWriteHandler, ContactRecord) {
        let harness = try await ContactsHarness()
        let books = try await harness.store.syncAddressBooks(
            [AddressBookRecord(loginId: harness.loginId, url: ContactsHarness.contactsBook)], loginId: harness.loginId)
        let ids = try await seedCards(harness, bookId: try #require(books.first?.id))
        let card = try #require(try await harness.store.contact(id: ids.fav))
        return (harness, ContactWriteHandler(store: harness.store, client: harness.client), card)
    }

    @Test func favouriteAppliesLocallySendsAPropPatchAndDiscardRestores() async throws {
        let (harness, handler, card) = try await handlerSetup()
        let write = DAVWrite(
            operationId: 3, kind: .contactFavorite, accountId: 1,
            payload: ContactWriteHandler.favoritePayload(loginId: harness.loginId, contact: card, favorite: true))
        let id = try #require(card.id)

        try await handler.apply(write)
        #expect(try await harness.store.contact(id: id)?.isFavorite == true)
        #expect(await harness.transport.sendCount == 1)  // seedCards' multiget only

        await harness.transport.stub(.proppatch, with: try .fixture("dav-ws35-favorite-proppatch.xml", status: 207))
        try await handler.send(write)
        let patch = try #require(await harness.transport.requests.last)
        #expect(patch.httpMethod == "PROPPATCH")
        #expect(patch.url?.path == Self.favHref)
        #expect(String(decoding: patch.httpBody ?? Data(), as: UTF8.self).contains("<nc:favorite>1</nc:favorite>"))

        await handler.revert(write)
        #expect(try await harness.store.contact(id: id)?.isFavorite == false)
        // Only the flag moved: the vCard and ETag are still the server's.
        let after = try #require(try await harness.store.contact(id: id))
        #expect(after.vcard == card.vcard && after.etag == card.etag)
    }

    @Test func twoFoldedTogglesDiscardToTheFirstState() async throws {
        let (harness, _, card) = try await handlerSetup()
        let on = ContactWriteHandler.favoritePayload(loginId: harness.loginId, contact: card, favorite: true)
        var starred = card
        starred.isFavorite = true
        let off = ContactWriteHandler.favoritePayload(loginId: harness.loginId, contact: starred, favorite: false)
        let folded = on.merging(off)
        #expect(folded.enabled == false)
        #expect(folded.before.isFavorite == false)
    }

    @Test func socialAvatarAsksTheServerAndWakesTheSync() async throws {
        let harness = try await ContactsHarness()
        let books = try await harness.store.syncAddressBooks(
            [AddressBookRecord(loginId: harness.loginId, url: ContactsHarness.contactsBook)], loginId: harness.loginId)
        let ids = try await seedCards(harness, bookId: try #require(books.first?.id))
        let card = try #require(try await harness.store.contact(id: ids.social))
        let woke = Woke()
        let handler = ContactWriteHandler(
            store: harness.store, client: harness.client, afterSend: { _ in await woke.mark() })
        let payload = try #require(
            ContactWriteHandler.socialAvatarPayload(
                loginId: harness.loginId, contact: card, bookURL: ContactsHarness.contactsBook, network: "GRAVATAR"))
        let write = DAVWrite(operationId: 4, kind: .contactSocialAvatar, accountId: 1, payload: payload)
        await harness.transport.stub(.method("PUT"), with: try .fixture("contacts-social-avatar.json", status: 200))

        try await handler.apply(write)
        try await handler.send(write)

        let request = try #require(await harness.transport.requests.last)
        #expect(request.url?.path == "/index.php/apps/contacts/api/v1/social/avatar/gravatar/contacts/ws35-social")
        #expect(await woke.count == 1)
    }

    @Test func socialAvatarNeedsAUID() async throws {
        let card = ContactRecord(addressBookId: 1, href: "/x.vcf", vcard: "", syncedAt: 0)
        #expect(
            ContactWriteHandler.socialAvatarPayload(
                loginId: 1, contact: card, bookURL: ContactsHarness.contactsBook, network: "gravatar") == nil)
    }

    @Test func collectionURIIsTheLastSegment() {
        #expect(ContactWriteHandler.collectionURI(ContactsHarness.contactsBook) == "contacts")
        #expect(ContactWriteHandler.collectionURI("/remote.php/dav/addressbooks/users/u/nhgj/") == "nhgj")
    }
}

private actor Woke {
    private(set) var count = 0
    func mark() { count += 1 }
}
