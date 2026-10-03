// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NCMailTestSupport

@Suite("MailStoreFixtures")
struct MailStoreFixturesTests {
    /// Every row the seed wrote, read back the way the message list reads them.
    ///
    /// Through `observeMessages`' sibling rather than raw SQL: `MailStore.read` is internal
    /// now, because handing out GRDB's `Database` is what put GRDB in the app's link line
    /// (ADR-0029). A window wider than the seed returns all of it.
    private func rows(
        _ store: MailStore,
        _ seed: MailStoreFixtures.SeedResult,
        upTo limit: Int
    ) async throws -> [MessageRow] {
        try await store.messages(mailboxId: seed.mailboxId, view: .flat, range: 0..<limit)
    }

    @Test("seed writes the requested number of distinct, non-identical envelopes")
    func seedsDistinctEnvelopes() async throws {
        let store = try MailStore.inMemory()
        let result = try await MailStoreFixtures.seed(store, messages: 500)
        #expect(result.messageIds.count == 500)

        let rows = try await rows(store, result, upTo: 1000)
        #expect(rows.count == 500)

        // Not every row alike: an index or a ranking test against one repeated subject would
        // pass for reasons that have nothing to do with the code under test.
        #expect(Set(rows.compactMap(\.subject)).count > 1)

        let threads = Set(rows.compactMap(\.threadRootId))
        #expect(threads.count > 1)
        #expect(threads.count < 500)
    }

    @Test("bodyFraction stores a proportional, non-trivial number of bodies")
    func seedsBodies() async throws {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: 100, bodyFraction: 0.1)

        let bodies = try await rows(store, seed, upTo: 200).filter { $0.bodyState == .present }
        #expect(bodies.count > 0)
        #expect(bodies.count < 100)
    }

    @Test("a zero bodyFraction writes no bodies at all")
    func noBodiesByDefault() async throws {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: 50)
        let bodies = try await rows(store, seed, upTo: 100).filter { $0.bodyState == .present }
        #expect(bodies.isEmpty)
    }
}
