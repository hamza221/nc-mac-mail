// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import GRDB
import NCMailStore
import Testing

@testable import NCMailTestSupport

@Suite("MailStoreFixtures")
struct MailStoreFixturesTests {
    @Test("seed writes the requested number of distinct, non-identical envelopes")
    func seedsDistinctEnvelopes() async throws {
        let store = try MailStore.inMemory()
        let result = try await MailStoreFixtures.seed(store, messages: 500)
        #expect(result.messageIds.count == 500)

        let total = try await store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0 }
        #expect(total == 500)

        let distinctSubjects = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(DISTINCT subject) FROM message") ?? 0
        }
        // Not every row alike: an index or a ranking test against one repeated subject would
        // pass for reasons that have nothing to do with the code under test.
        #expect(distinctSubjects > 1)

        let distinctThreads = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(DISTINCT threadRootId) FROM message") ?? 0
        }
        #expect(distinctThreads > 1)
        #expect(distinctThreads < 500)
    }

    @Test("bodyFraction stores a proportional, non-trivial number of bodies")
    func seedsBodies() async throws {
        let store = try MailStore.inMemory()
        _ = try await MailStoreFixtures.seed(store, messages: 100, bodyFraction: 0.1)

        let bodies = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messageBody") ?? 0
        }
        #expect(bodies > 0)
        #expect(bodies < 100)
    }

    @Test("a zero bodyFraction writes no bodies at all")
    func noBodiesByDefault() async throws {
        let store = try MailStore.inMemory()
        _ = try await MailStoreFixtures.seed(store, messages: 50)
        let bodies = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messageBody") ?? 0
        }
        #expect(bodies == 0)
    }
}
