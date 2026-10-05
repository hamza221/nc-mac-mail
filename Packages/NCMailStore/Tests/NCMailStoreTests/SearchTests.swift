// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// Every string in this suite is written here rather than taken from a fixture.
///
/// The recorded fixtures were captured with `--scrub-content`: every subject in them is the
/// literal "Subject redacted" and every sender label is "Name redacted". A search test over a
/// corpus with one distinct subject and one distinct sender would pass with the ranking
/// weights set to anything at all.
@Suite("Search")
struct SearchTests {
    // MARK: - The corpus

    /// Four messages with deliberately overlapping words, so ranking has something to rank and
    /// a term can be made to appear in one column and not another.
    static func corpus(_ store: MailStore) async throws -> [Int64] {
        try await Seed.base(store)
        let ids = try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1,
                sentAt: 100,
                subject: "Quarterly hedgehog census",
                preview: "Numbers are up in the eastern hedgerow",
                addresses: [EnvelopeAddress(kind: .from, email: "zoe@example.invalid", label: "Zoë Baker")]
            ),
            Seed.envelope(
                remoteId: 2,
                sentAt: 200,
                subject: "Dragonfly Inn opening menu",
                preview: "The quick brown fox course is still on the list",
                isSeen: true,
                addresses: [
                    EnvelopeAddress(kind: .from, email: "sookie@dragonfly.invalid", label: "Sookie St. James"),
                    EnvelopeAddress(kind: .cc, email: "lorelai@dragonfly.invalid", label: "Lorelai Gilmore"),
                ]
            ),
            Seed.envelope(
                remoteId: 3,
                sentAt: 300,
                subject: "Re: the roadmap",
                preview: "Brown quick is not the same phrase at all",
                addresses: [EnvelopeAddress(kind: .from, email: "luke@diner.invalid", label: "Luke Danes")]
            ),
            Seed.envelope(
                remoteId: 4,
                sentAt: 400,
                subject: "Lunch",
                preview: "Nothing to see here",
                addresses: [EnvelopeAddress(kind: .from, email: "kirk@stars.invalid", label: "Kirk Gleason")]
            ),
        ])
        // Only the fourth message mentions hedgehogs in its body, which is what separates a
        // subject hit from a body hit when the ranking is under test.
        let fourth = try #require(ids.last)
        try await store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1,
                hasHtmlBody: true,
                html: "<p>A passing remark about a hedgehog, four hundred words in.</p>"
            ),
            for: fourth
        )
        return ids
    }

    static func ids(_ store: MailStore, _ text: String, scope: SearchQuery.Scope = .all) async throws -> [Int64] {
        try await store.search(SearchQuery(text: text, scope: scope), limit: 50).map(\.id)
    }

    // MARK: - Nothing in, nothing out

    @Test(arguments: ["", " ", "\t\n  ", "-", "*", "(", "()", "\"", "😀", "— ·"])
    func inputWithNothingToMatchFindsNothing(_ text: String) async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        #expect(try await Self.ids(store, text).isEmpty, "\(text.debugDescription) matched something")
    }

    // MARK: - Prefixes

    /// Terms need two characters (WS-32); prefix matching works from the second one.
    @Test(arguments: ["he", "hed", "hedgeh", "hedgehog"])
    func prefixMatchingWorksFromTheSecondCharacter(_ text: String) async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let first = try #require(ids.first)
        #expect(try await Self.ids(store, text).contains(first))
    }

    /// `remove_diacritics 2` in the schema is what makes this true. The indexed label is
    /// `Zo\u{eb}`-with-a-diaeresis, so every one of these is a fold in one direction or
    /// the other.
    @Test(arguments: ["Zoe", "Zoë", "zoe", "ZOË", "zoë"])
    func diacriticsAreFoldedBothWays(_ text: String) async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let first = try #require(ids.first)
        #expect(try await Self.ids(store, text).contains(first))
    }

    // MARK: - Terms and phrases

    @Test func severalTermsAllHaveToMatch() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let second = try #require(ids.dropFirst().first)
        #expect(try await Self.ids(store, "dragonfly menu") == [second])
        // "menu" is in message two and "roadmap" in message three, so together they are nobody.
        #expect(try await Self.ids(store, "menu roadmap").isEmpty)
    }

    @Test func aQuotedPhraseStaysAPhrase() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let second = try #require(ids.dropFirst().first)
        let third = try #require(ids.dropFirst(2).first)
        #expect(try await Self.ids(store, "\"quick brown\"") == [second])
        #expect(try await Self.ids(store, "\"brown quick\"") == [third])
        // Unquoted, the two words are an AND and order stops mattering.
        #expect(try await Self.ids(store, "quick brown").sorted() == [second, third].sorted())
    }

    /// Typing an opening quote is a state every search field passes through. It must not be a
    /// syntax error for the fourteen keystrokes it takes to close it.
    @Test func anUnclosedQuoteIsStillAValidQuery() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let second = try #require(ids.dropFirst().first)
        #expect(try await Self.ids(store, "\"quick bro") == [second])
    }

    // MARK: - Nothing the user types is an operator

    /// FTS5's grammar has `AND`, `OR`, `NOT`, `NEAR`, column filters, grouping and prefix
    /// stars in it. None of them may be reachable from the search field: the query has to mean
    /// what it looks like it means, and it must never throw.
    @Test(
        arguments: [
            "NOT", "AND", "OR", "NEAR", "not hedgehog", "hedgehog NOT census",
            "subject:hedgehog", "subject : hedgehog", "^hedgehog", "hedgehog*", "*hedgehog",
            "(hedgehog", "hedgehog)", "(hedgehog OR lunch)", "hedge-hog", "-hedgehog",
            "\"", "\"\"", "\"\"\"", "a\"b", "NEAR(hedgehog lunch, 2)",
            "😀 hedgehog", "Ω hedgehog", "{hedgehog}", "[hedgehog]", "hedgehog;--",
            "'; DROP TABLE message; --", "%hedgehog%", "hedgehog\u{0}census",
        ]
    )
    func everyOperatorAndPunctuationMarkIsJustText(_ text: String) async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        // The assertion is that this returns rather than throws. A syntax error out of FTS5
        // reaches the user as an empty list with no explanation, which is the failure the
        // escaping exists to prevent.
        let results = try await Self.ids(store, text)
        #expect(results.count <= 4)
    }

    /// `NOT` as a word finds the word, and does not subtract anything.
    @Test func typingAnOperatorSearchesForThatWord() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let ids = try await store.upsert(envelopes: [
            Seed.envelope(remoteId: 1, sentAt: 100, subject: "Definitely not a hedgehog", preview: ""),
            Seed.envelope(remoteId: 2, sentAt: 200, subject: "A hedgehog", preview: ""),
        ])
        let containsNot = try #require(ids.first)
        #expect(try await Self.ids(store, "hedgehog NOT") == [containsNot])
    }

    /// A paste into the search field is one keystroke, and an unbounded expression is a
    /// thrown error on the way to the screen rather than a slow query.
    @Test func aVeryLongQueryIsTruncatedRatherThanRejected() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let paste = (1...500).map { "word\($0)" }.joined(separator: " ")
        #expect(try await Self.ids(store, paste).isEmpty)
        let expression = try #require(FTS5MatchExpression.build(from: paste))
        #expect(expression.components(separatedBy: " AND ").count == FTS5MatchExpression.maximumTerms)
    }

    // MARK: - Scope

    @Test func scopeNarrowsToAMailboxAnAccountOrNothing() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        // A second mailbox on the same account, and a second account entirely.
        let second = try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Archive")], accountId: 1)
        let archive = try #require(second.first)
        try await store.upsert(envelopes: [
            Seed.envelope(remoteId: 10, mailboxId: archive.id, sentAt: 500, subject: "Archived hedgehog", preview: "")
        ])

        let identity = ServerIdentity(serverURL: "https://two.example.invalid/", loginName: "grace")
        let others = try await store.upsert(accounts: [Seed.account(remoteId: 1, identity: identity)])
        let other = try #require(others.first)
        let otherMailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(accountId: other.id, remoteId: 10, name: "INBOX", displayName: "INBOX", isSubscribed: true)
            ],
            accountId: other.id
        )
        let otherMailbox = try #require(otherMailboxes.first)
        try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1,
                mailboxId: otherMailbox.id,
                accountId: other.id,
                sentAt: 600,
                subject: "Second-server hedgehog",
                preview: ""
            )
        ])

        #expect(try await Self.ids(store, "hedgehog", scope: .mailbox(10)).count == 2)
        #expect(try await Self.ids(store, "hedgehog", scope: .mailbox(archive.id)).count == 1)
        #expect(try await Self.ids(store, "hedgehog", scope: .account(1)).count == 3)
        #expect(try await Self.ids(store, "hedgehog", scope: .account(other.id)).count == 1)
        // `.all` spans accounts, which is the point of one database for every signed-in login.
        #expect(try await Self.ids(store, "hedgehog", scope: .all).count == 4)
    }

    @Test func aResultSaysWhichMailboxItCameFrom() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let results = try await store.search(SearchQuery(text: "hedgehog"), limit: 10)
        let first = try #require(results.first)
        #expect(first.mailboxName == "INBOX")
        #expect(first.accountId == 1)
    }

    // MARK: - Flags

    @Test func flagFiltersNarrowWithoutChangingTheMatch() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let second = try #require(ids.dropFirst().first)
        let unread = try await store.search(
            SearchQuery(text: "the", flags: .init(unreadOnly: true)), limit: 50
        ).map(\.id)
        // Message two is the only one marked read, so it is the only one this drops.
        #expect(unread.contains(second) == false)
        #expect(unread.count == 2)

        // An all-false filter is the same query as no filter at all.
        let allFalse = try await store.search(SearchQuery(text: "the", flags: .init()), limit: 50).map(\.id)
        let none = try await store.search(SearchQuery(text: "the"), limit: 50).map(\.id)
        #expect(allFalse == none)
        #expect(none.count == 3)
    }

    // MARK: - Ranking

    /// The weights ADR-0011 asked for, checked against the one case that would show them
    /// missing: the same word in a subject and in a body four hundred words long.
    @Test func aSubjectHitOutranksABodyHit() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let subjectHit = try #require(ids.first)
        let bodyHit = try #require(ids.last)
        let order = try await Self.ids(store, "hedgehog")
        #expect(order.prefix(2) == [subjectHit, bodyHit])
    }

    @Test func aPersonHitOutranksAPreviewHit() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let ids = try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1,
                sentAt: 100,
                subject: "Menus",
                preview: "Sookie is cooking again",
                addresses: [EnvelopeAddress(kind: .from, email: "luke@diner.invalid", label: "Luke Danes")]
            ),
            Seed.envelope(
                remoteId: 2,
                sentAt: 200,
                subject: "Menus",
                preview: "Nothing in particular",
                addresses: [EnvelopeAddress(kind: .from, email: "sookie@dragonfly.invalid", label: "Sookie St. James")]
            ),
        ])
        let fromSookie = try #require(ids.dropFirst().first)
        #expect(try await Self.ids(store, "sookie").first == fromSookie)
    }

    // MARK: - Staying in step with the mirror

    @Test func aMessageDeletedLocallyLeavesTheResults() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let first = try #require(ids.first)
        #expect(try await Self.ids(store, "hedgehog").contains(first))
        try await store.deleteMessages(ids: [first])
        #expect(try await Self.ids(store, "hedgehog").contains(first) == false)
    }

    /// Deleting the account cascades to its messages without Swift naming one, which is why
    /// the index delete is a trigger (ADR-0024). Search has to see that too.
    @Test func deletingAnAccountEmptiesItsResults() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        try await store.deleteAccount(id: 1)
        #expect(try await Self.ids(store, "hedgehog").isEmpty)
    }

    /// "Remove local copies" empties the body column. Envelopes stay searchable, which is the
    /// point of the control.
    @Test func removingLocalCopiesKeepsEnvelopesSearchable() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let subjectHit = try #require(ids.first)
        let bodyHit = try #require(ids.last)
        try await store.removeLocalCopies(accountId: 1, resetBodyState: true)
        let after = try await Self.ids(store, "hedgehog")
        #expect(after == [subjectHit])
        #expect(after.contains(bodyHit) == false)
    }

    @Test func aLiveSearchDeliversAgainWhenAMatchingRowChanges() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let first = try #require(ids.first)

        var iterator = store.observeSearchRows(SearchQuery(text: "hedgehog"), range: 0..<50).makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.map(\.id).contains(first))

        try await store.deleteMessages(ids: [first])
        let next = try #require(try await iterator.next())
        #expect(next.map(\.id).contains(first) == false)
    }

    // MARK: - Coverage

    /// The footer's first value, through the same observation the footer uses.
    static func coverage(_ store: MailStore, _ scope: SearchQuery.Scope) async throws -> SearchCoverage {
        var iterator = store.observeSearchCoverage(scope: scope).makeAsyncIterator()
        return try #require(try await iterator.next())
    }

    @Test func coverageCountsBodiesAgainstEveryDownloadedMessage() async throws {
        let store = try MailStore.inMemory()
        let ids = try await Self.corpus(store)
        let coverage = try await Self.coverage(store, .all)
        #expect(coverage.totalMessages == 4)
        #expect(coverage.indexedMessages == 1)
        #expect(coverage.isComplete == false)

        // A body that will never arrive still counts as settled, or the footer never leaves.
        try await store.setBodyState(.failed, messageIds: Array(ids.dropLast()))
        let settled = try await Self.coverage(store, .all)
        #expect(settled.failedMessages == 3)
        #expect(settled.isComplete)
    }

    @Test func coverageFollowsTheScope() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let mailboxes = try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Archive")], accountId: 1)
        let archive = try #require(mailboxes.first)
        #expect(try await Self.coverage(store, .mailbox(10)).totalMessages == 4)
        #expect(try await Self.coverage(store, .mailbox(archive.id)).totalMessages == 0)
        // An empty scope is complete rather than 0 of 0 forever on screen.
        #expect(try await Self.coverage(store, .mailbox(archive.id)).isComplete)
    }

    // MARK: - The list's window

    /// WS-08's list installs `observeSearchRows` and windows `0..<n` with `n` growing, so the
    /// same shape has to hold here as it does for a mailbox.
    @Test func theRowWindowGrowsFromZero() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        var narrow = store.observeSearchRows(SearchQuery(text: "the"), range: 0..<1).makeAsyncIterator()
        var wide = store.observeSearchRows(SearchQuery(text: "the"), range: 0..<60).makeAsyncIterator()
        #expect(try #require(try await narrow.next()).count == 1)
        #expect(try #require(try await wide.next()).count == 3)
        // An empty window asks the database nothing.
        var none = store.observeSearchRows(SearchQuery(text: "the"), range: 0..<0).makeAsyncIterator()
        #expect(try #require(try await none.next()).isEmpty)
    }

    @Test func offsetWalksTheRanking() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let all = try await store.search(SearchQuery(text: "hedgehog"), limit: 10).map(\.id)
        let second = try await store.search(SearchQuery(text: "hedgehog"), limit: 1, offset: 1).map(\.id)
        #expect(second == Array(all.dropFirst().prefix(1)))
    }
}

/// The translation on its own, without a database in the way.
///
/// Every case here is a string somebody can type. The suite above proves the queries run; this
/// one pins what they say, because "no crash" and "the right query" are different claims.
@Suite("FTS5 expressions")
struct FTS5MatchExpressionTests {
    @Test(arguments: [
        ("hedgehog", "\"hedgehog\"*"),
        ("  hedgehog  ", "\"hedgehog\"*"),
        ("quick brown", "\"quick\"* AND \"brown\"*"),
        ("\"quick brown\"", "\"quick brown\""),
        ("\"quick brown\" fox", "\"quick brown\" AND \"fox\"*"),
        ("NOT", "\"NOT\"*"),
        ("ab\"cd", "\"ab\"* AND \"cd\"*"),
        ("a\"bc", "\"bc\"*"),
        ("\"quick bro", "\"quick bro\"*"),
        // Punctuation separates tokens here exactly as it did on the way into the index,
        // so what reaches SQLite is only ever letters, digits and single spaces.
        ("hedge-hog", "\"hedge hog\"*"),
        ("subject:hedgehog", "\"subject hedgehog\"*"),
        ("(hedgehog OR lunch)", "\"hedgehog\"* AND \"OR\"* AND \"lunch\"*"),
        ("hedgehog\u{0}census", "\"hedgehog census\"*"),
    ])
    func theExpressionSaysWhatItLooksLike(_ input: String, _ expected: String) {
        #expect(FTS5MatchExpression.build(from: input) == expected)
    }

    @Test(arguments: ["", "   ", "-", "*", "()", "\"", "\"\"", "😀", "·—"])
    func inputWithNoTokensHasNoExpression(_ input: String) {
        #expect(FTS5MatchExpression.build(from: input) == nil)
    }

    /// Every quote is a delimiter, so no expression this builds ever carries an odd number
    /// of them. That is the property the escaping in `render` exists to hold, and it is worth
    /// asserting over the whole alphabet rather than over one hand-picked string.
    @Test(arguments: ["\"say \"\"hello\"", "a\"b\"c\"", "\"\"\"\"", "one \"two three", "\"\"x\"\""])
    func noExpressionEverCarriesAnUnbalancedQuote(_ input: String) {
        guard let expression = FTS5MatchExpression.build(from: input) else { return }
        #expect(expression.filter { $0 == "\"" }.count % 2 == 0)
    }

    @Test func termsAreCappedRatherThanUnbounded() {
        let many = (1...200).map { "w\($0)" }.joined(separator: " ")
        let expression = FTS5MatchExpression.build(from: many)
        #expect(expression?.components(separatedBy: " AND ").count == FTS5MatchExpression.maximumTerms)
    }

    /// Anything at all, one character at a time, must produce either nil or something FTS5
    /// parses. The alphabet is the operators, the punctuation and the letters they hide in.
    @Test func randomInputNeverProducesASyntaxError() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(remoteId: 1, sentAt: 100)])

        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcNOTANDORNEAR \"'()*^:-_{}[]%;\\/.,\u{0}é😀\t\n0123456789")
        for _ in 0..<500 {
            let length = Int.random(in: 0...24, using: &generator)
            let text = String((0..<length).compactMap { _ in alphabet.randomElement(using: &generator) })
            // Throwing here is the failure. The result set is not the point; a query that
            // FTS5 rejects reaches the user as an unexplained empty list.
            _ = try await store.search(SearchQuery(text: text), limit: 10)
        }
    }
}
