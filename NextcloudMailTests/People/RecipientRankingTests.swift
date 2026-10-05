// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import Testing

@testable import NextcloudMail

/// ADR-0072's ranking and dedup, from rows alone.
@Suite("RecipientRanking")
struct RecipientRankingTests {
    private func contact(_ id: Int64, _ name: String, _ email: String?, position: Int = 0) -> ContactSuggestionRow {
        ContactSuggestionRow(contactId: id, addressBookId: 1, displayName: name, email: email, emailPosition: position)
    }

    private func stat(_ email: String, count: Int, lastSeen: Int64, label: String? = nil) -> MailAddressStatistic {
        MailAddressStatistic(email: email, label: label, count: count, lastSeenAt: lastSeen)
    }

    private func server(_ email: String?, label: String, source: String = "collector") -> RecipientSuggestionRecord {
        RecipientSuggestionRecord(
            loginId: 1, term: "x", position: 0, email: email, label: label, source: source, fetchedAt: 0)
    }

    @Test("contacts by recent interaction, then mail by frequency, then server, identities last")
    func bucketsInOrder() {
        var input = RecipientRanking.Input()
        input.contacts = [contact(1, "Old Friend", "old@x.example"), contact(2, "New Friend", "new@x.example")]
        input.lastSeen = ["old@x.example": 100, "new@x.example": 900]
        input.mailMatches = [
            stat("rare@x.example", count: 1, lastSeen: 999), stat("often@x.example", count: 7, lastSeen: 5),
        ]
        input.server = [server("server@x.example", label: "Server Only")]
        input.identityMatches = [OwnIdentity(accountId: 1, email: "me@x.example", name: "Me")]
        input.ownEmails = ["me@x.example"]

        let ranked = RecipientRanking.rank(input, limit: 20)
        #expect(
            ranked.map(\.email) == [
                "new@x.example", "old@x.example", "often@x.example", "rare@x.example", "server@x.example",
                "me@x.example",
            ])
        #expect(ranked.last?.kind == .identity(accountId: 1))
        #expect(ranked[2].kind == .mail(count: 7))
    }

    @Test("never-mailed contacts follow mailed ones, by name")
    func unmailedContactsByName() {
        var input = RecipientRanking.Input()
        input.contacts = [
            contact(1, "Zed", "z@x.example"), contact(2, "Abe", "a@x.example"), contact(3, "Mailed", "m@x.example"),
        ]
        input.lastSeen = ["m@x.example": 1]
        #expect(RecipientRanking.rank(input, limit: 20).map(\.label) == ["Mailed", "Abe", "Zed"])
    }

    @Test("an address appears once, under its best source, case-insensitively")
    func dedup() {
        var input = RecipientRanking.Input()
        input.contacts = [contact(1, "Ada", "Ada@X.example"), contact(2, "Ada again", "ada@x.example")]
        input.mailMatches = [
            stat("ada@x.example", count: 50, lastSeen: 1), stat("other@x.example", count: 1, lastSeen: 1),
        ]
        input.server = [server("ADA@x.example", label: "Ada"), server("other@x.example", label: "Other")]
        let ranked = RecipientRanking.rank(input, limit: 20)
        #expect(ranked.map { $0.email?.lowercased() } == ["ada@x.example", "other@x.example"])
        #expect(ranked.first?.kind == .contact(contactId: 1))
        #expect(ranked.last?.kind == .mail(count: 1))
    }

    @Test("an own address in the system address book is shown only as an identity, last")
    func identityWinsOverSystemBook() {
        var input = RecipientRanking.Input()
        input.contacts = [contact(1, "admin", "admin@x.example"), contact(2, "Alice", "alice@x.example")]
        input.mailMatches = [stat("admin@x.example", count: 99, lastSeen: 99)]
        input.server = [server("admin@x.example", label: "admin", source: "contacts")]
        input.identityMatches = [OwnIdentity(accountId: 3, email: "admin@x.example", name: "admin")]
        input.ownEmails = ["admin@x.example"]
        let ranked = RecipientRanking.rank(input, limit: 20)
        #expect(ranked.map(\.email) == ["alice@x.example", "admin@x.example"])
        #expect(ranked.last?.kind == .identity(accountId: 3))
    }

    @Test("a contact group expands to its members and ranks by its most recent member")
    func groups() {
        var input = RecipientRanking.Input()
        input.contacts = [
            ContactSuggestionRow(contactId: 9, addressBookId: 1, displayName: "Team", isGroup: true),
            contact(1, "Quiet", "quiet@x.example"),
            ContactSuggestionRow(contactId: 10, addressBookId: 1, displayName: "Empty group", isGroup: true),
        ]
        let members = [
            RecipientAddress(email: "a@x.example", label: "A"), RecipientAddress(email: "b@x.example", label: "B"),
        ]
        input.groupMembers = [9: members]
        input.lastSeen = ["b@x.example": 50]
        let ranked = RecipientRanking.rank(input, limit: 20)
        #expect(ranked.map(\.id) == ["group:9", "quiet@x.example"])
        #expect(ranked.first?.expandedAddresses == members)
        #expect(ranked.first?.email == nil)
    }

    @Test("a server group without a single address is kept by label; a nextcloud: group by its address")
    func serverGroups() {
        var input = RecipientRanking.Input()
        input.server = [
            server("nextcloud:admin", label: "admin (Nextcloud)", source: "groups"), server(nil, label: "No address"),
        ]
        let ranked = RecipientRanking.rank(input, limit: 20)
        #expect(ranked.map(\.id) == ["nextcloud:admin", "server:No address"])
        #expect(ranked.last?.expandedAddresses == [])
    }

    @Test("the list is capped")
    func limit() {
        var input = RecipientRanking.Input()
        input.mailMatches = (0..<50).map { stat("p\($0)@x.example", count: $0, lastSeen: 0) }
        #expect(RecipientRanking.rank(input, limit: 20).count == 20)
    }

    @Test("terms match word prefixes of the name or text inside the address, ignoring case and accents")
    func termMatching() {
        let words = RecipientTerm.words("Zoë O'Brien zoe.obrien@example.com")
        #expect(RecipientTerm("zoe").matches(emailLowercased: "zoe.obrien@example.com", words: words))
        #expect(RecipientTerm("ZOË bri").matches(emailLowercased: "x@y", words: words))
        #expect(RecipientTerm("brien@exa").matches(emailLowercased: "zoe.obrien@example.com", words: []))
        #expect(!RecipientTerm("rien").matches(emailLowercased: "x@y", words: words))
        #expect(RecipientTerm("  ").isEmpty)
    }
}

@Suite("ContactCardActions")
struct ContactCardActionsTests {
    private let base =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:u1\r\nFN:Luke Danes\r\nEMAIL;TYPE=WORK:luke@diner.example\r\nEND:VCARD\r\n"

    @Test("adding an address appends one EMAIL and keeps everything else")
    func addEmail() throws {
        let card = try #require(try ContactCardActions.card(adding: "luke@home.example", to: base))
        #expect(card.emails.map(\.value) == ["luke@diner.example", "luke@home.example"])
        #expect(card.formattedName == "Luke Danes")
        #expect(card.uid == "u1")
    }

    @Test("adding an address the card already has is a no-op")
    func addExisting() throws {
        #expect(try ContactCardActions.card(adding: "LUKE@diner.example", to: base) == nil)
    }

    @Test("an unreadable card is refused rather than overwritten")
    func unreadable() {
        #expect(throws: ContactCardActions.Failure.unreadableCard) {
            try ContactCardActions.card(adding: "a@b.example", to: "not a vcard")
        }
    }

    @Test("a new card carries UID, FN, N and the address, and round-trips through the parser")
    func newCard() throws {
        let card = ContactCardActions.newCard(name: "Taylor Doose, Jr", email: "taylor@x.example", uid: "abc")
        let text = String(decoding: VCardSerializer.serialize(card), as: UTF8.self)
        let parsed = try #require(try VCardParser.parse(text).first)
        #expect(parsed.uid == "abc")
        #expect(parsed.formattedName == "Taylor Doose, Jr")
        #expect(parsed.name?.family == "Jr")
        #expect(parsed.name?.given == "Taylor Doose,")
        #expect(parsed.emails.map(\.value) == ["taylor@x.example"])
    }

    @Test("a nameless new card is named by its address")
    func namelessCard() {
        #expect(ContactCardActions.newCard(name: " ", email: "a@x.example", uid: "u").formattedName == "a@x.example")
    }

    @Test("the new href is the book's path plus <UID>.vcf")
    func href() {
        #expect(
            ContactCardActions.newHref(
                bookURL: "http://localhost/remote.php/dav/addressbooks/users/admin/contacts/", uid: "u-1")
                == "/remote.php/dav/addressbooks/users/admin/contacts/u-1.vcf")
        #expect(ContactCardActions.newHref(bookURL: "http://h/a/b", uid: "x") == "/a/b/x.vcf")
    }
}

@Suite("RecentMailItem")
struct RecentMailItemTests {
    private func row(_ id: Int64, messageId: String?, sentAt: Int64) -> RecentMailRow {
        RecentMailRow(
            id: id, mailboxId: 1, accountId: 1, messageId: messageId, subject: "s\(id)", sentAt: sentAt,
            fromEmail: nil, fromLabel: nil, isSeen: true)
    }

    @Test("copies of one message collapse to the first (newest) and the limit counts messages")
    func collapse() {
        let rows = [
            row(1, messageId: "<a>", sentAt: 30), row(2, messageId: "<a>", sentAt: 30),
            row(3, messageId: nil, sentAt: 20),
            row(4, messageId: nil, sentAt: 10),
        ]
        #expect(RecentMailItem.collapse(rows, limit: 10).map(\.messageId) == [1, 3, 4])
        #expect(RecentMailItem.collapse(rows, limit: 2).map(\.messageId) == [1, 3])
    }
}
