// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Message queries")
struct MessageQueryTests {
    @Test func theFlatListIsNewestFirstAndWindowed() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...10).map { Seed.envelope(remoteId: $0, sentAt: 1_700_000_000 + $0) }
        )

        let firstPage = try await store.messages(mailboxId: 10, view: .flat, range: 0..<3)
        #expect(firstPage.map(\.id) == [10, 9, 8])

        let secondPage = try await store.messages(mailboxId: 10, view: .flat, range: 3..<6)
        #expect(secondPage.map(\.id) == [7, 6, 5])

        #expect(try await store.messages(mailboxId: 10, view: .flat, range: 0..<0).isEmpty)
    }

    @Test func theFlatListCountsOnlyItsOwnUnreadState() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 1, sentAt: 100, isSeen: true),
                Seed.envelope(remoteId: 2, sentAt: 200, isSeen: false),
            ]
        )
        // Newest first, so the unseen message with the later `sentAt` leads.
        let rows = try await store.messages(mailboxId: 10, view: .flat, range: 0..<2)
        #expect(rows.map(\.id) == [2, 1])
        #expect(rows.map(\.threadCount) == [1, 1])
        #expect(rows.map(\.threadUnreadCount) == [1, 0])
    }

    @Test func theThreadedListShowsTheNewestOfEachThreadWithItsCounts() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 1, sentAt: 100, threadRootId: "t1", isSeen: true),
                Seed.envelope(remoteId: 2, sentAt: 200, threadRootId: "t1", isSeen: false),
                Seed.envelope(remoteId: 3, sentAt: 300, threadRootId: "t1", isSeen: false),
                Seed.envelope(remoteId: 4, sentAt: 250, threadRootId: "t2", isSeen: true),
            ]
        )

        let rows = try await store.messages(mailboxId: 10, view: .threaded, range: 0..<10)
        #expect(rows.map(\.id) == [3, 4])
        #expect(rows.map(\.threadCount) == [3, 1])
        #expect(rows.map(\.threadUnreadCount) == [2, 0])
    }

    /// A message the server gave no thread key is a thread of one. `=` never matches NULL, so
    /// without the explicit branch in the query these disappear from the threaded list
    /// entirely — which is the kind of bug that looks like sync losing mail.
    @Test func theThreadedListKeepsMessagesWithNoThreadKey() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 1, sentAt: 100, threadRootId: nil),
                Seed.envelope(remoteId: 2, sentAt: 200, threadRootId: nil, isSeen: true),
                Seed.envelope(remoteId: 3, sentAt: 300, threadRootId: "t1"),
            ]
        )
        let rows = try await store.messages(mailboxId: 10, view: .threaded, range: 0..<10)
        #expect(rows.map(\.id) == [3, 2, 1])
        #expect(rows.map(\.threadCount) == [1, 1, 1])
        #expect(rows.map(\.threadUnreadCount) == [1, 0, 1])
    }

    @Test func theThreadedListIsWindowedTheSameWayAsTheFlatOne() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...20).map {
                Seed.envelope(remoteId: $0, sentAt: 1_700_000_000 + $0, threadRootId: "t\($0 % 4)")
            }
        )
        let rows = try await store.messages(mailboxId: 10, view: .threaded, range: 0..<2)
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == [20, 19])
    }

    /// An index that quietly stops being used is how a fast list becomes a slow one between two
    /// releases, and nothing in a functional test would notice.
    ///
    /// The sorter assertion is not pedantry. A `TEMP B-TREE` here means SQLite buffers every
    /// qualifying row before the LIMIT applies, and the per-row thread counts are then computed
    /// for all of them: 201 ms instead of 0.4 ms at 50,000 rows, measured.
    @Test func theThreadedListUsesTheThreadIndex() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...50).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0, threadRootId: "t\($0 % 7)") })

        let plan = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN " + MessageSQL.threadedList,
                arguments: ["mailboxId": 10, "limit": 50, "offset": 0]
            ).map { $0["detail"] as String }
        }
        let text = plan.joined(separator: "\n")
        #expect(text.contains("idxMessageThread"), "threaded list plan:\n\(text)")
        #expect(!text.contains("SCAN m"), "the threaded list must not scan the table:\n\(text)")
        #expect(!text.contains("TEMP B-TREE"), "a sorter here defeats the LIMIT:\n\(text)")
    }

    @Test func theFlatListUsesTheMailboxSentIndex() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...50).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })

        let plan = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN " + MessageSQL.flatList,
                arguments: ["mailboxId": 10, "limit": 50, "offset": 0]
            ).map { $0["detail"] as String }
        }
        let text = plan.joined(separator: "\n")
        #expect(text.contains("idxMessageMailboxSent"), "flat list plan:\n\(text)")
        #expect(!text.contains("SCAN m"), "the flat list must not scan the table:\n\(text)")
        #expect(!text.contains("TEMP B-TREE"), "a sorter here defeats the LIMIT:\n\(text)")
    }

    @Test func theBackfillPickerUsesItsIndex() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...50).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })

        let plan = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id FROM message
                     WHERE accountId = 1 AND bodyState = 'missing'
                     ORDER BY sentAt DESC LIMIT 10
                    """
            ).map { $0["detail"] as String }
        }
        let text = plan.joined(separator: "\n")
        #expect(text.contains("idxMessageBodyState"), "backfill picker plan:\n\(text)")
        #expect(!text.contains("SCAN"), "the backfill picker must not scan:\n\(text)")
    }

    @Test func aThreadReadsOldestFirst() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 1, sentAt: 300, threadRootId: "t1"),
                Seed.envelope(remoteId: 2, sentAt: 100, threadRootId: "t1"),
                Seed.envelope(remoteId: 3, sentAt: 200, threadRootId: "t1"),
                Seed.envelope(remoteId: 4, sentAt: 150, threadRootId: "other"),
            ]
        )
        var received: [MessageRow] = []
        for try await rows in store.observeThread(rootId: "t1", mailboxId: 10) {
            received = rows
            break
        }
        #expect(received.map(\.id) == [2, 3, 1])
    }

    @Test func theBackfillPickerTakesTheNewestMissingBodies() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...10).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })
        try await store.setBodyState(.present, messageIds: [9, 10])

        let batch = try await store.nextBodyBackfillBatch(accountId: 1, limit: 3)
        // Both ids, because the fetch needs the server's and the write needs the mirror's.
        #expect(batch.map(\.id) == [8, 7, 6])
        #expect(batch.map(\.remoteId) == [8, 7, 6])
        #expect(try await store.nextBodyBackfillBatch(accountId: 2, limit: 3).isEmpty)
    }
}
