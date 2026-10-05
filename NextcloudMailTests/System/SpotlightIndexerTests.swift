// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// What Spotlight would hold, in memory: the real `CSSearchableIndex` stores items fine
/// from a sandboxed app, but what is worth asserting is which items are written and
/// deleted when, from a seeded mirror.
actor InMemorySpotlightIndex: SpotlightIndexing {
    private(set) var items: [String: SpotlightEntry] = [:]
    private(set) var upserted: [String] = []
    private(set) var deleted: [String] = []
    private(set) var clearedDomains: [String] = []

    func upsert(_ entries: [SpotlightEntry]) async throws {
        for entry in entries {
            items[entry.identifier] = entry
            upserted.append(entry.identifier)
        }
    }

    func delete(identifiers: [String]) async throws {
        for identifier in identifiers { items[identifier] = nil }
        deleted += identifiers
    }

    func deleteAll(domain: String) async throws {
        items = items.filter { $0.value.kind.domain != domain }
        clearedDomains.append(domain)
    }

    func resetLog() {
        upserted = []
        deleted = []
    }
}

@Suite("Spotlight indexer")
struct SpotlightIndexerTests {
    @Test func messagesAreIndexedThenOnlyTheirChangesWritten() async throws {
        var fixture = try await SystemFixture.make()
        let first = try await fixture.message(remoteId: 1, subject: "Quarterly numbers", sender: "Alice")
        let second = try await fixture.message(remoteId: 2, mailboxId: fixture.archiveId, subject: "Lunch")
        let index = InMemorySpotlightIndex()
        let indexer = SpotlightIndexer(index: index)

        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.clearedDomains == ["messages"])
        let items = await index.items
        #expect(Set(items.keys) == ["message:\(first)", "message:\(second)"])
        let entry = try #require(items["message:\(first)"])
        #expect(entry.title == "Quarterly numbers")
        #expect(entry.people == ["Alice"])
        #expect(entry.emails == ["alice@example.invalid"])
        #expect(entry.detail == "Preview 1")
        #expect(SpotlightIdentifier.link(for: entry.identifier) == .message(first))

        // A flag Spotlight does not show writes nothing.
        await index.resetLog()
        try await fixture.message(remoteId: 1, subject: "Quarterly numbers", isSeen: true, sender: "Alice")
        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.upserted.isEmpty)
        #expect(await index.deleted.isEmpty)

        // A changed subject rewrites that one item.
        try await fixture.message(remoteId: 1, subject: "Q3 numbers", isSeen: true, sender: "Alice")
        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.upserted == ["message:\(first)"])
        #expect(await index.items["message:\(first)"]?.title == "Q3 numbers")

        // A row deleted from the mirror leaves Spotlight.
        await index.resetLog()
        try await fixture.store.deleteMessages(ids: [second])
        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.deleted == ["message:\(second)"])
        #expect(await index.upserted.isEmpty)
        #expect(Set(await index.items.keys) == ["message:\(first)"])
        // The domain is replaced once per launch, not on every value.
        #expect(await index.clearedDomains == ["messages"])
    }

    @Test func contactsAreIndexedWithTheirAddressesAndLeaveWithTheirLogin() async throws {
        let fixture = try await SystemFixture.make()
        let index = InMemorySpotlightIndex()
        let indexer = SpotlightIndexer(index: index)
        let store = fixture.store
        let emails: @Sendable (Int64) async -> [String] = { id in
            ((try? await store.contactEmails(contactId: id)) ?? []).map(\.email)
        }

        await indexer.updateContacts(
            try await store.contacts(addressBookId: fixture.bookId), loginId: fixture.loginId, emails: emails)
        let ada = try #require(fixture.contacts["Ada Lovelace"])
        let grace = try #require(fixture.contacts["Grace Hopper"])
        let items = await index.items
        // The group card is not a person to find.
        #expect(Set(items.keys) == ["contact:\(ada)", "contact:\(grace)"])
        #expect(items["contact:\(ada)"]?.title == "Ada Lovelace")
        #expect(items["contact:\(ada)"]?.emails == ["ada@example.invalid"])
        #expect(await index.clearedDomains == ["contacts"])

        // Unchanged cards are not rewritten; a new one is.
        await index.resetLog()
        let alan = try await fixture.addContact(name: "Alan Turing", email: "alan@example.invalid")
        await indexer.updateContacts(
            try await store.contacts(addressBookId: fixture.bookId), loginId: fixture.loginId, emails: emails)
        #expect(await index.upserted == ["contact:\(alan)"])

        // A deleted card is deleted.
        await index.resetLog()
        try await store.deleteContact(addressBookId: fixture.bookId, href: "/grace@example.invalid.vcf")
        await indexer.updateContacts(
            try await store.contacts(addressBookId: fixture.bookId), loginId: fixture.loginId, emails: emails)
        #expect(await index.deleted == ["contact:\(grace)"])

        // Signing the login out takes the rest.
        await indexer.removeContacts(loginId: fixture.loginId)
        #expect(await index.items.isEmpty)
    }

    /// ADR-0099's window: the newest `messageLimit` rows. The oldest message, pushed out by
    /// newer ones, leaves Spotlight like a deleted one does.
    @Test func onlyTheNewestWindowIsIndexed() async throws {
        let fixture = try await SystemFixture.make()
        let index = InMemorySpotlightIndex()
        let indexer = SpotlightIndexer(index: index)
        let limit = SpotlightIndexer.messageLimit
        let ids = try await fixture.store.upsert(
            envelopes: (1...Int64(limit)).map {
                EnvelopeWrite(
                    remoteId: $0, mailboxId: fixture.inboxId, accountId: fixture.accountId, sentAt: $0,
                    syncedAt: $0, subject: "S\($0)")
            })
        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.items.count == limit)

        await index.resetLog()
        try await fixture.store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: Int64(limit) + 1, mailboxId: fixture.inboxId, accountId: fixture.accountId,
                sentAt: Int64(limit) + 1, syncedAt: 0, subject: "Newest")
        ])
        await indexer.updateMessages(try await fixture.allRows())
        #expect(await index.items.count == limit)
        let oldest = try #require(ids.first)
        #expect(await index.deleted == ["message:\(oldest)"])
        #expect(await index.upserted.count == 1)
    }
}
