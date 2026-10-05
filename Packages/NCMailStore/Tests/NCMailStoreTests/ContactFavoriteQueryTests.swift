// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailStore

/// WS-35: the favourite flag's two writers — the queue's local effect and the sync's
/// per-pass listing (ADR-0092) — and the login-wide list the Contacts section reads.
@Suite("contact favourites")
struct ContactFavoriteQueryTests {
    private struct Seeded {
        var loginId: Int64
        var own: Int64
        var hidden: Int64
    }

    private func seed(_ store: MailStore) async throws -> Seeded {
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [
                AddressBookRecord(loginId: loginId, url: "https://x.invalid/contacts/", position: 0),
                AddressBookRecord(loginId: loginId, url: "https://x.invalid/hidden/", isEnabled: false, position: 1),
            ],
            loginId: loginId
        )
        return Seeded(loginId: loginId, own: try #require(books[0].id), hidden: try #require(books[1].id))
    }

    @discardableResult
    private func card(
        _ store: MailStore, book: Int64, href: String, name: String, favorite: Bool = false
    )
        async throws -> Int64
    {
        let row = try await store.upsert(
            contact: ContactRecord(
                addressBookId: book, href: href, vcard: "BEGIN:VCARD\nEND:VCARD", displayName: name,
                isFavorite: favorite, syncedAt: 0))
        return try #require(row.id)
    }

    @Test func setContactFavoriteTouchesOnlyTheFlag() async throws {
        let store = try MailStore.inMemory()
        let seeded = try await seed(store)
        let id = try await card(store, book: seeded.own, href: "/a.vcf", name: "Ada")
        let before = try #require(try await store.contact(id: id))

        try await store.setContactFavorite(true, contactId: id)
        var after = try #require(try await store.contact(id: id))
        #expect(after.isFavorite)
        after.isFavorite = false
        #expect(after == before)
    }

    @Test func listingMakesExactlyTheListedCardsFavouritesExceptHeldOnes() async throws {
        let store = try MailStore.inMemory()
        let seeded = try await seed(store)
        let ada = try await card(store, book: seeded.own, href: "/a.vcf", name: "Ada", favorite: true)
        let bob = try await card(store, book: seeded.own, href: "/b.vcf", name: "Bob")
        let cyd = try await card(store, book: seeded.own, href: "/c.vcf", name: "Cyd", favorite: true)

        // Ada unfavourited elsewhere, Bob favourited elsewhere, Cyd's local toggle is queued.
        let moved = try await store.syncContactFavorites(
            addressBookId: seeded.own, favoriteHrefs: ["/b.vcf"], heldHrefs: ["/c.vcf"])
        #expect(moved == 2)
        #expect(try await store.contact(id: ada)?.isFavorite == false)
        #expect(try await store.contact(id: bob)?.isFavorite == true)
        #expect(try await store.contact(id: cyd)?.isFavorite == true)

        // The same listing again changes nothing.
        #expect(
            try await store.syncContactFavorites(
                addressBookId: seeded.own, favoriteHrefs: ["/b.vcf"], heldHrefs: ["/c.vcf"]) == 0)
    }

    @Test func loginListIsEnabledBooksFavouritesFirst() async throws {
        let store = try MailStore.inMemory()
        let seeded = try await seed(store)
        try await card(store, book: seeded.own, href: "/a.vcf", name: "Ada")
        try await card(store, book: seeded.own, href: "/z.vcf", name: "Zed", favorite: true)
        try await card(store, book: seeded.hidden, href: "/h.vcf", name: "Hidden", favorite: true)

        var iterator = store.observeContacts(loginId: seeded.loginId).makeAsyncIterator()
        let rows = try #require(try await iterator.next())
        #expect(rows.compactMap(\.displayName) == ["Zed", "Ada"])
    }
}
