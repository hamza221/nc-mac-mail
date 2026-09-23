// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// What a search costs at fifty thousand messages.
///
/// Measurements, not thresholds, on the same terms as ``PerformanceTests``: each case reports
/// its number to stderr and asserts a ceiling well above the target, because a tight
/// assertion on a shared machine fails for reasons that have nothing to do with the query.
/// The ceiling still catches the thing worth catching, which is the index falling out of use.
///
/// The corpus is `PerformanceTests.seed`: fifty thousand envelopes through the real write
/// path, with ten subject topics, five hundred senders and a distinct preview per message. A
/// corpus of one repeated subject would make any set of weights look correct.
///
/// The index's size on disk is measured by `PerformanceTests.sizingOfAMirrorOnDisk`, which
/// already separates the body text from the index over it against bodies recorded from a live
/// server. Duplicating that here would measure the same thing twice.
@Suite("Search performance", .serialized)
struct SearchPerformanceTests {
    /// The brief's number: results have to be on screen inside a frame while somebody types.
    static let budgetMilliseconds = 50.0

    /// Five shapes of query, because they cost different things. The one-character prefix is
    /// the worst case and also the first one every search runs: it matches most of the
    /// corpus, and `ORDER BY bm25(...)` has to score every match before the window is taken.
    static let shapes: [(name: String, text: String)] = [
        ("one character", "m"),
        ("a common word", "quick brown"),
        ("a topic phrase", "\"quarterly numbers\""),
        ("a rare word", "hedgehogs"),
        ("a person", "sender 417"),
    ]

    @Test func searchIsFastAtFiftyThousandMessages() async throws {
        let store = try MailStore.inMemory()
        let seedMilliseconds = try await PerformanceTests.seed(store)
        reportMeasurement("seeded \(PerformanceTests.messageCount) envelopes in \(ms(seedMilliseconds)) ms")

        for shape in Self.shapes {
            let query = SearchQuery(text: shape.text, scope: .mailbox(10))
            // Warm the statement cache once. The number that matters is the steady state,
            // which is what every keystroke after the first pays.
            _ = try await store.search(query, limit: 50)
            let elapsed = try await PerformanceTests.best(of: 5) {
                _ = try await store.search(query, limit: 50)
            }
            reportMeasurement("\(shape.name) (\(try await hits(store, shape.text))), first 50: \(ms(elapsed)) ms")
            #expect(elapsed < Self.budgetMilliseconds * 10, "\(shape.name) took \(ms(elapsed)) ms")
        }
    }

    /// Scope switching changes the query plan rather than filtering the same result set, so
    /// it gets its own number: [ux-spec.md](../../../../docs/product/ux-spec.md#search) says
    /// the control is instant.
    @Test func scopeSwitchingCostsNothingExtra() async throws {
        let store = try MailStore.inMemory()
        _ = try await PerformanceTests.seed(store)

        for (name, scope) in [
            ("this mailbox", SearchQuery.Scope.mailbox(10)),
            ("this account", .account(1)),
            ("all mail", .all),
        ] {
            let query = SearchQuery(text: "hedgehogs", scope: scope)
            _ = try await store.search(query, limit: 50)
            let elapsed = try await PerformanceTests.best(of: 5) {
                _ = try await store.search(query, limit: 50)
            }
            reportMeasurement("scope \(name): \(ms(elapsed)) ms")
            #expect(elapsed < Self.budgetMilliseconds * 10, "scope \(name) took \(ms(elapsed)) ms")
        }
    }

    /// The footer's counter runs alongside the search on every keystroke, so it is part of
    /// the round trip whether or not it feels like it.
    @Test func theCoverageCounterIsCheap() async throws {
        let store = try MailStore.inMemory()
        _ = try await PerformanceTests.seed(store)
        _ = try await store.searchCoverage(scope: .all)
        let elapsed = try await PerformanceTests.best(of: 5) {
            _ = try await store.searchCoverage(scope: .all)
        }
        reportMeasurement("coverage counter over \(PerformanceTests.messageCount): \(ms(elapsed)) ms")
        #expect(elapsed < Self.budgetMilliseconds * 10)
    }

    /// The same queries against a mirror of a real account, through the public API.
    ///
    /// Off by default, because it reads a file and every other test in this package uses an
    /// in-memory database. Make the file with the sync package's live mirror test and point
    /// this at what it leaves behind:
    ///
    /// ```
    /// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin \
    ///   NCMAIL_LIVE_PASSWORD=admin NCMAIL_LIVE_KEEP=1 \
    ///   swift test --package-path ../NCMailSync --filter mirrorsAWholeAccount
    /// NCMAIL_LIVE_MIRROR_FILE="$TMPDIR/ncmail-live/mirror.sqlite" \
    ///   swift test --filter searchesARealMirror
    /// ```
    ///
    /// No network is reachable from here and none is needed: `NCMailStore` cannot see
    /// `NCMailNet`, so "search works offline" is a fact about the link line rather than a
    /// claim this test could weaken by passing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR_FILE"] != nil))
    func searchesARealMirror() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR_FILE"])
        let store = try MailStore(url: URL(filePath: path))
        let coverage = try await store.searchCoverage(scope: .all)
        reportMeasurement(
            "live mirror: \(coverage.indexedMessages) of \(coverage.totalMessages) searchable, "
                + "\(coverage.unmirroredMailboxes) mailboxes not downloaded"
        )

        for text in ["p", "palestine", "NOT", "\"", "-", "😀", "re test"] {
            let elapsed = try await PerformanceTests.best(of: 3) {
                _ = try await store.search(SearchQuery(text: text, scope: .all), limit: 50)
            }
            let results = try await store.search(SearchQuery(text: text, scope: .all), limit: 50)
            reportMeasurement("live \(text.debugDescription): \(results.count) hits in \(ms(elapsed)) ms")
        }

        // Whether the weights order real mail sensibly, said as a number rather than by
        // printing somebody's subjects: a subject is exactly the sort of thing that must
        // never reach a log or a terminal, gated test or not.
        let term = ProcessInfo.processInfo.environment["NCMAIL_LIVE_TERM"] ?? "a"
        let ranked = try await store.search(SearchQuery(text: term, scope: .all), limit: 50)
        let inSubject = { (result: SearchResult) in
            result.message.subject?.range(of: term, options: .caseInsensitive) != nil
        }
        let topTen = ranked.prefix(10).count(where: inSubject)
        reportMeasurement(
            "live ranking of \(ranked.count) hits: \(topTen) of the top 10 carry the term in "
                + "the subject, \(ranked.count(where: inSubject)) of all of them do"
        )
        #expect(coverage.totalMessages > 0)
    }

    /// How many messages a query matches, counted without decoding any of them.
    private func hits(_ store: MailStore, _ text: String) async throws -> String {
        guard let match = FTS5MatchExpression.build(from: text) else { return "no expression" }
        let count = try await store.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM messageSearch WHERE messageSearch MATCH ?",
                arguments: [match]
            ) ?? 0
        }
        return "\(count) hits"
    }
}

private func ms(_ value: Double) -> String {
    String(format: "%.3f", value)
}
