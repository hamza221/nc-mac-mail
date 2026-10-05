// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailStore

/// The read-only queries behind WS-26's autocomplete, contact card and recent-mail list.
@Suite("people queries")
struct PeopleQueryTests {
    private func seedBooks(_ store: MailStore) async throws -> (loginId: Int64, own: Int64, disabled: Int64) {
        let login = try await store.ensureLogin(Seed.identity)
        let loginId = try #require(login.id)
        let books = try await store.syncAddressBooks(
            [
                AddressBookRecord(loginId: loginId, url: "https://x.invalid/contacts/", position: 0),
                AddressBookRecord(loginId: loginId, url: "https://x.invalid/hidden/", isEnabled: false, position: 1),
            ],
            loginId: loginId
        )
        return (loginId, try #require(books[0].id), try #require(books[1].id))
    }

    private func contact(
        _ store: MailStore, book: Int64, href: String, name: String, uid: String? = nil, emails: [String],
        isGroup: Bool = false, members: [String] = []
    ) async throws -> Int64 {
        let row = try await store.upsert(
            contact: ContactRecord(
                addressBookId: book, href: href, uid: uid, vcard: "BEGIN:VCARD\nEND:VCARD", displayName: name,
                isGroup: isGroup, syncedAt: 0),
            emails: emails.enumerated().map {
                ContactEmailRecord(contactId: 0, position: $0.offset, email: $0.element)
            },
            memberUids: members
        )
        return try #require(row.id)
    }

    @Test func contactSuggestionsMatchPrefixesOfEveryWordInEnabledBooksOnly() async throws {
        let store = try MailStore.inMemory()
        let books = try await seedBooks(store)
        let lorelai = try await contact(
            store, book: books.own, href: "/l.vcf", name: "Lorelai Gilmore",
            emails: ["lorelai@dragonfly.example", "lg@home.example"])
        _ = try await contact(
            store, book: books.own, href: "/r.vcf", name: "Rory Gilmore", emails: ["rory@yale.example"])
        _ = try await contact(
            store, book: books.disabled, href: "/h.vcf", name: "Lorelai Hidden", emails: ["hidden@example"])

        let one = try await store.contactSuggestions(matching: "l", loginId: books.loginId, limit: 100)
        #expect(Set(one.map(\.contactId)) == [lorelai])
        #expect(Set(one.compactMap(\.email)) == ["lorelai@dragonfly.example", "lg@home.example"])

        let both = try await store.contactSuggestions(matching: "gilm", loginId: books.loginId, limit: 100)
        #expect(Set(both.compactMap(\.email)).count == 3)

        let byAddress = try await store.contactSuggestions(matching: "rory@ya", loginId: books.loginId, limit: 100)
        #expect(byAddress.map(\.email) == ["rory@yale.example"])

        #expect(try await store.contactSuggestions(matching: "@-(", loginId: books.loginId, limit: 100).isEmpty)
        #expect(try await store.contactSuggestions(matching: "NOT", loginId: books.loginId, limit: 100).isEmpty)
    }

    @Test func groupMembersResolveByUidToTheirFirstAddress() async throws {
        let store = try MailStore.inMemory()
        let books = try await seedBooks(store)
        _ = try await contact(
            store, book: books.own, href: "/a.vcf", name: "Ada", uid: "u-ada",
            emails: ["ada@x.example", "a2@x.example"])
        _ = try await contact(store, book: books.own, href: "/b.vcf", name: "Bob", uid: "u-bob", emails: [])
        let group = try await contact(
            store, book: books.own, href: "/g.vcf", name: "Team", emails: [], isGroup: true,
            members: ["u-ada", "u-bob", "u-missing"])

        let members = try await store.groupMemberAddresses(groupIds: [group])
        #expect(members.map(\.email) == ["ada@x.example"])
        #expect(members.first?.groupId == group)
    }

    @Test func mailStatisticsCountAndKeepTheNewestLabel() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        _ = try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1, sentAt: 100,
                addresses: [EnvelopeAddress(kind: .from, email: "Sookie@Example.invalid", label: "Sookie")]),
            Seed.envelope(
                remoteId: 2, sentAt: 300,
                addresses: [
                    EnvelopeAddress(kind: .from, email: "sookie@example.invalid", label: "Sookie St. James"),
                    EnvelopeAddress(kind: .to, email: "michel@example.invalid", label: nil),
                ]),
        ])
        let stats = try await store.mailAddressStatistics(accountIds: [1])
        let sookie = try #require(stats.first { $0.email.lowercased() == "sookie@example.invalid" })
        #expect(sookie.count == 2)
        #expect(sookie.lastSeenAt == 300)
        #expect(sookie.label == "Sookie St. James")
        #expect(stats.count == 2)
        #expect(try await store.mailAddressStatistics(accountIds: [99]).isEmpty)
    }

    @Test func recentMailFindsAnyHeaderNewestFirst() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        _ = try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1, sentAt: 100, subject: "old",
                addresses: [EnvelopeAddress(kind: .from, email: "luke@example.invalid", label: "Luke")]),
            Seed.envelope(
                remoteId: 2, sentAt: 200, subject: "cc",
                addresses: [
                    EnvelopeAddress(kind: .from, email: "a@example.invalid", label: nil),
                    EnvelopeAddress(kind: .cc, email: "LUKE@example.invalid", label: nil),
                    EnvelopeAddress(kind: .bcc, email: "luke@example.invalid", label: nil),
                ]),
            Seed.envelope(remoteId: 3, sentAt: 300, subject: "unrelated"),
        ])
        let rows = try await store.recentMail(withAddress: "Luke@example.invalid", accountIds: [1], limit: 10)
        #expect(rows.map(\.subject) == ["cc", "old"])
        let limited = try await store.recentMail(withAddress: "luke@example.invalid", accountIds: [1], limit: 1)
        #expect(limited.map(\.subject) == ["cc"])
    }

    @Test func observedContactsByEmailAreLoginScopedAndLive() async throws {
        let store = try MailStore.inMemory()
        let books = try await seedBooks(store)
        var iterator = store.observeContacts(withEmail: "kirk@example.invalid", loginId: books.loginId)
            .makeAsyncIterator()
        #expect(try await iterator.next() == [])
        _ = try await contact(store, book: books.own, href: "/k.vcf", name: "Kirk", emails: ["KIRK@example.invalid"])
        let next = try await iterator.next()
        #expect(next?.map(\.displayName) == ["Kirk"])
    }
}
