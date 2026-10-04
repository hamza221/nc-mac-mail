// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import Testing

@testable import NextcloudMail

/// The list's pure part: scopes, web Contacts' sort, the groups.
@Suite("Contacts list ordering and scopes")
struct ContactsListingTests {
    private static func entry(
        _ id: Int64, fn: String? = nil, n: String? = nil, org: String? = nil, categories: String? = nil,
        rev: String? = nil, book: Int64 = 1, favorite: Bool = false, group: Bool = false
    ) -> ContactEntry? {
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "UID:\(id)"]
        if let fn { lines.append("FN:\(fn)") }
        if let n { lines.append("N:\(n)") }
        if let org { lines.append("ORG:\(org)") }
        if let categories { lines.append("CATEGORIES:\(categories)") }
        if let rev { lines.append("REV:\(rev)") }
        lines.append("END:VCARD")
        return ContactEntry(
            record: ContactRecord(
                id: id, addressBookId: book, href: "/\(id).vcf", vcard: lines.joined(separator: "\r\n") + "\r\n",
                displayName: fn, isGroup: group, isFavorite: favorite, syncedAt: 0))
    }

    private static let people: [ContactEntry] = [
        entry(1, fn: "Zack Van Gerbig", n: "Van Gerbig;Zack;;;", categories: "Band"),
        entry(2, fn: "anna Kim", n: "Kim;Anna;;;", rev: "20260101T000000Z", favorite: true),
        entry(3, fn: "Lane Kim", n: "Kim;Lane;;;", categories: "Band,Family", rev: "2026-03-01T10:00:00Z"),
        entry(4, org: "Luke's Diner", book: 2),
        entry(5, fn: "Band", group: true),
    ].compactMap { $0 }

    private func names(_ rows: [ContactEntry], _ order: ContactsSortOrder = .displayName) -> [String] {
        rows.map { $0.displayName(order: order) }
    }

    @Test func favouritesFirstThenDisplayNameCaseInsensitive() {
        let rows = ContactsListing.rows(Self.people, scope: .all, recentBookIds: [], matching: nil, order: .displayName)
        #expect(names(rows) == ["anna Kim", "Lane Kim", "Luke's Diner", "Zack Van Gerbig"])
    }

    @Test func lastNameOrderShowsAndSortsLastFirst() {
        let rows = ContactsListing.rows(Self.people, scope: .all, recentBookIds: [], matching: nil, order: .lastName)
        #expect(names(rows, .lastName) == ["Kim, Anna", "Kim, Lane", "Luke's Diner", "Van Gerbig, Zack"])
    }

    @Test func firstNameOrder() {
        let rows = ContactsListing.rows(
            Self.people.map {
                var e = $0; e.record.isFavorite = false; return e
            }, scope: .all, recentBookIds: [],
            matching: nil, order: .firstName)
        #expect(names(rows, .firstName) == ["Anna Kim", "Lane Kim", "Luke's Diner", "Zack Van Gerbig"])
    }

    /// REV: newest first, cards without one after them.
    @Test func lastModifiedOrder() {
        let rows = ContactsListing.rows(
            Self.people.map {
                var e = $0; e.record.isFavorite = false; return e
            }, scope: .all, recentBookIds: [],
            matching: nil, order: .rev)
        #expect(rows.map(\.id) == [3, 2, 1, 4])
    }

    @Test func scopes() {
        func ids(_ scope: ContactsScope, recent: Set<Int64> = []) -> [Int64] {
            ContactsListing.rows(Self.people, scope: scope, recentBookIds: recent, matching: nil, order: .displayName)
                .map(\.id)
        }
        #expect(ids(.favorites) == [2])
        #expect(ids(.addressBook(2)) == [4])
        #expect(ids(.group("Family")) == [3])
        #expect(ids(.group("Band")) == [3, 1])
        #expect(ids(.recent, recent: [2]) == [4])
        #expect(ids(.team("t")).isEmpty)
        // KIND:group cards are never listed.
        #expect(!ids(.all).contains(5))
    }

    @Test func searchMatchesFilterTheScope() {
        let rows = ContactsListing.rows(
            Self.people, scope: .all, recentBookIds: [], matching: [1, 4], order: .displayName)
        #expect(rows.map(\.id) == [4, 1])
    }

    @Test func groupsCountPeopleInNaturalOrder() {
        #expect(
            ContactsListing.groups(Self.people) == [
                ContactGroupSummary(name: "Band", count: 2), ContactGroupSummary(name: "Family", count: 1),
            ])
    }

    @Test func revisionParsesBothSpellings() {
        let basic = ContactEntry.parseRevision("20260301T100000Z")
        let extended = ContactEntry.parseRevision("2026-03-01T10:00:00.123Z")
        #expect(basic != nil && basic == extended)
        #expect(ContactEntry.parseRevision("2026-03-01") != nil)
        #expect(ContactEntry.parseRevision("junk") == nil)
    }

    @Test func recentlyContactedBookIsRecognised() {
        let recent = AddressBookRecord(
            loginId: 1,
            url: "https://x.example/remote.php/dav/addressbooks/users/u/z-app-generated--contactsinteraction--recent/")
        #expect(ContactsListing.isRecentlyContacted(recent))
        #expect(!ContactsListing.isRecentlyContacted(AddressBookRecord(loginId: 1, url: "https://x.example/contacts/")))
    }

    @Test func socialNetworksFollowTheCard() throws {
        let card = try #require(
            try VCardParser.parse(
                "BEGIN:VCARD\r\nVERSION:3.0\r\nEMAIL:a@b.example\r\nX-SOCIALPROFILE;TYPE=MASTODON:@a@m.example\r\nX-SOCIALPROFILE;TYPE=twitter:a\r\nEND:VCARD\r\n"
            ).first)
        #expect(ContactsActions.socialNetworks(for: card) == ["mastodon", "gravatar"])
    }

    @Test func defaultBookAndReadOnlyReason() {
        let own = AddressBookRecord(id: 1, loginId: 1, url: "https://x.example/addressbooks/users/u/contacts/")
        let other = AddressBookRecord(id: 2, loginId: 1, url: "https://x.example/addressbooks/users/u/work/")
        let shared = AddressBookRecord(
            id: 3, loginId: 1, url: "https://x.example/addressbooks/users/u/team_shared_by_b/", displayName: "Team",
            isReadOnly: true, sharedBy: "Bob")
        #expect(ContactsActions.defaultBook(for: .all, books: [other, own, shared])?.id == 1)
        #expect(ContactsActions.defaultBook(for: .addressBook(2), books: [other, own, shared])?.id == 2)
        #expect(ContactsActions.defaultBook(for: .addressBook(3), books: [shared]) == nil)
        #expect(ContactsActions.readOnlyReason(own) == nil)
        #expect(ContactsActions.readOnlyReason(shared)?.contains("Bob") == true)
    }
}
