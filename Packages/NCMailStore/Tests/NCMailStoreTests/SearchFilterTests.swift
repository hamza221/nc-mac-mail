// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// One query test per search filter (WS-32): the chips, every field of the "Search
/// parameters" sheet, the two-character rule, and how they combine.
///
/// The corpus is written here rather than taken from a fixture for the same reason as
/// ``SearchTests``: recorded fixtures are scrubbed to one subject and one sender.
@Suite("Search filters")
struct SearchFilterTests {
    /// The four messages, by the role each plays.
    struct Corpus {
        var attachedUnread: Int64
        var aliasStarredWork: Int64
        var bodyImportantFamily: Int64
        var ccMeBothTags: Int64
    }

    /// Account 1 is `test@example.invalid` with the alias `me-alias@example.invalid`.
    static func corpus(_ store: MailStore) async throws -> Corpus {
        try await Seed.base(store)
        try await store.replaceAliases(
            [
                AliasRecord(
                    accountId: 1, remoteId: 1, email: "me-alias@example.invalid", provisioned: false, rawJSON: "{}")
            ],
            accountId: 1
        )
        let work = TagWrite(remoteId: 1, imapLabel: "work", displayName: "Work")
        let family = TagWrite(remoteId: 2, imapLabel: "family", displayName: "Family", color: "#00ff00")

        var first = Seed.envelope(
            remoteId: 1, sentAt: 1000, subject: "Budget review", preview: "Numbers inside",
            addresses: [
                EnvelopeAddress(kind: .from, email: "alice@x.invalid", label: "Alice"),
                EnvelopeAddress(kind: .to, email: "test@example.invalid"),
            ]
        )
        first.hasAttachments = true

        var second = Seed.envelope(
            remoteId: 2, sentAt: 2000, subject: "Garden party", preview: "The budget was mentioned",
            isSeen: true,
            addresses: [
                EnvelopeAddress(kind: .from, email: "bob@x.invalid", label: "Bob"),
                EnvelopeAddress(kind: .to, email: "Me-Alias@Example.INVALID"),
                EnvelopeAddress(kind: .cc, email: "carol@x.invalid"),
            ]
        )
        second.isFlagged = true
        second.tags = [work]

        var third = Seed.envelope(
            remoteId: 3, sentAt: 3000, subject: "Hello", preview: "Nothing here",
            addresses: [
                EnvelopeAddress(kind: .from, email: "alice@x.invalid", label: "Alice"),
                EnvelopeAddress(kind: .to, email: "dave@x.invalid"),
                EnvelopeAddress(kind: .bcc, email: "test@example.invalid"),
            ]
        )
        third.isImportant = true
        third.mentionsMe = true
        third.tags = [family]

        var fourth = Seed.envelope(
            remoteId: 4, sentAt: 4000, subject: "Budget final", preview: "Signed off",
            isSeen: true,
            addresses: [
                EnvelopeAddress(kind: .from, email: "carol@x.invalid", label: "Carol"),
                EnvelopeAddress(kind: .to, email: "dave@x.invalid"),
                EnvelopeAddress(kind: .to, email: "erin@x.invalid"),
                EnvelopeAddress(kind: .cc, email: "test@example.invalid"),
            ]
        )
        fourth.tags = [work, family]

        let ids = try await store.upsert(envelopes: [first, second, third, fourth])
        try #require(ids.count == 4)
        try await store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: true, html: "<p>The budget is in the body.</p>"),
            for: ids[2]
        )
        return Corpus(
            attachedUnread: ids[0], aliasStarredWork: ids[1], bodyImportantFamily: ids[2], ccMeBothTags: ids[3])
    }

    static func ids(
        _ store: MailStore,
        text: String = "",
        scope: SearchQuery.Scope = .all,
        flags: SearchQuery.FlagFilter? = nil,
        _ parameters: SearchQuery.Parameters = .init()
    ) async throws -> [Int64] {
        try await store.search(SearchQuery(text: text, scope: scope, flags: flags, parameters: parameters), limit: 50)
            .map(\.id)
    }

    // MARK: - Chips

    @Test func hasAttachmentChip() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(withAttachmentsOnly: true)) == [c.attachedUnread])
    }

    @Test func unreadChip() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        // Filters alone: newest first.
        #expect(try await Self.ids(store, flags: .init(unreadOnly: true)) == [c.bodyImportantFamily, c.attachedUnread])
    }

    /// The account address or an alias, in `To:`, case-insensitively. A copy in Cc or Bcc
    /// is not "to me".
    @Test func toMeChip() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(toMeOnly: true)) == [c.aliasStarredWork, c.attachedUnread])
    }

    @Test func toMeUsesEachAccountsOwnIdentities() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        // A second account whose own address is someone else's; mail to test@ there is not to it.
        let identity = ServerIdentity(serverURL: "https://two.example.invalid/", loginName: "grace")
        var account = Seed.account(remoteId: 1, identity: identity)
        account.emailAddress = "grace@two.invalid"
        let other = try #require(try await store.upsert(accounts: [account]).first)
        let mailbox = try #require(
            try await store.upsert(
                mailboxes: [
                    MailboxWrite(
                        accountId: other.id, remoteId: 10, name: "INBOX", displayName: "INBOX", isSubscribed: true)
                ],
                accountId: other.id
            ).first
        )
        let ids = try await store.upsert(envelopes: [
            Seed.envelope(
                remoteId: 1, mailboxId: mailbox.id, accountId: other.id, sentAt: 5000,
                addresses: [
                    EnvelopeAddress(kind: .to, email: "test@example.invalid")
                ]),
            Seed.envelope(
                remoteId: 2, mailboxId: mailbox.id, accountId: other.id, sentAt: 6000,
                addresses: [
                    EnvelopeAddress(kind: .to, email: "GRACE@two.invalid")
                ]),
        ])
        let toGrace = try #require(ids.last)
        #expect(try await Self.ids(store, scope: .account(other.id), flags: .init(toMeOnly: true)) == [toGrace])
    }

    // MARK: - Sheet: text fields

    @Test func subjectSearchesOnlyTheSubject() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        // "budget" is also in message two's preview and message three's body.
        let hits = try await Self.ids(store, .init(subject: "budget"))
        #expect(Set(hits) == [c.attachedUnread, c.ccMeBothTags])
    }

    @Test func bodySearchesOnlyTheBody() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, .init(body: "budget")) == [c.bodyImportantFamily])
    }

    @Test func subjectAndBodyTermsAreTypedTextNotSyntax() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        for text in ["NOT", "subject:budget", "\"", "(budget OR x)", "body : x", "'; DROP TABLE message; --"] {
            _ = try await Self.ids(store, .init(subject: text, body: text))
        }
        let expression = FTS5MatchExpression.build([("budget", nil), ("final", .subject), ("is", .body)])
        #expect(expression == "\"budget\"* AND subject : \"final\"* AND body : \"is\"*")
    }

    // MARK: - Sheet: date range

    /// Half-open: the start is included, the end is not.
    @Test func dateRange() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(
            try await Self.ids(store, .init(sentAfter: 2000, sentBefore: 4000))
                == [c.bodyImportantFamily, c.aliasStarredWork]
        )
        #expect(try await Self.ids(store, .init(sentAfter: 3500)) == [c.ccMeBothTags])
        #expect(try await Self.ids(store, .init(sentBefore: 1001)) == [c.attachedUnread])
    }

    // MARK: - Sheet: addresses

    @Test func fromTakesOneAddressCaseInsensitively() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        let expected = [c.bodyImportantFamily, c.attachedUnread]
        #expect(try await Self.ids(store, .init(from: "alice@x.invalid")) == expected)
        #expect(try await Self.ids(store, .init(from: "  ALICE@X.invalid ")) == expected)
        // A recipient is not a sender.
        #expect(try await Self.ids(store, .init(from: "dave@x.invalid")).isEmpty)
    }

    @Test func toMatchesAnyOfItsAddresses() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, .init(to: ["erin@x.invalid"])) == [c.ccMeBothTags])
        #expect(
            try await Self.ids(store, .init(to: ["dave@x.invalid", "ERIN@x.invalid", "dave@x.invalid", " "]))
                == [c.ccMeBothTags, c.bodyImportantFamily]
        )
    }

    @Test func ccMatchesOnlyCc() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, .init(cc: ["carol@x.invalid"])) == [c.aliasStarredWork])
        #expect(try await Self.ids(store, .init(cc: ["test@example.invalid"])) == [c.ccMeBothTags])
    }

    @Test func bccMatchesOnlyBcc() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, .init(bcc: ["test@example.invalid"])) == [c.bodyImportantFamily])
    }

    // MARK: - Sheet: tags and toggles

    @Test func tagsMatchAnyOfTheirLabels() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, .init(tags: ["work"])) == [c.ccMeBothTags, c.aliasStarredWork])
        #expect(
            try await Self.ids(store, .init(tags: ["work", "family"]))
                == [c.ccMeBothTags, c.bodyImportantFamily, c.aliasStarredWork]
        )
        #expect(try await Self.ids(store, .init(tags: ["nonexistent"])).isEmpty)
    }

    @Test func importantToggle() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(importantOnly: true)) == [c.bodyImportantFamily])
    }

    @Test func favoriteToggle() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(starredOnly: true)) == [c.aliasStarredWork])
    }

    @Test func mentionsMeToggle() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(mentionsMeOnly: true)) == [c.bodyImportantFamily])
    }

    // MARK: - Rules

    @Test(arguments: ["b", "x", " b ", "\"b\"", "a b c"])
    func termsNeedTwoCharacters(_ text: String) async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        #expect(FTS5MatchExpression.build(from: text) == nil)
        #expect(SearchQuery(text: text).hasCriteria == false)
        #expect(SearchQuery(text: "", parameters: .init(subject: text, body: text)).hasCriteria == false)
        #expect(try await Self.ids(store, text: text).isEmpty)
    }

    /// A short term next to a real one is dropped rather than spoiling the query.
    @Test func aShortTermBesideALongOneIsIgnored() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, text: "b final") == [c.ccMeBothTags])
        #expect(try await Self.ids(store, text: "bu final") == [c.ccMeBothTags])
    }

    @Test func noCriteriaFindsNothing() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        #expect(try await Self.ids(store, flags: .init(), .init(from: " ", to: ["", "  "])).isEmpty)
        #expect(SearchQuery(text: "", flags: .init()).hasCriteria == false)
        #expect(SearchQuery.Parameters().isEmpty)
    }

    /// Fields combine with AND; text keeps the ranking (subject above body).
    @Test func filtersCombineWithTextAndKeepTheRanking() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(
            try await Self.ids(store, text: "budget", flags: .init(unreadOnly: true), .init(from: "alice@x.invalid"))
                == [c.attachedUnread, c.bodyImportantFamily]
        )
        #expect(
            try await Self.ids(
                store, text: "budget",
                flags: .init(unreadOnly: true, importantOnly: true),
                .init(sentAfter: 0, from: "alice@x.invalid", bcc: ["test@example.invalid"], tags: ["family"])
            ) == [c.bodyImportantFamily]
        )
        #expect(try await Self.ids(store, flags: .init(starredOnly: true), .init(tags: ["family"])).isEmpty)
    }

    @Test func scopeAppliesToFilterOnlySearches() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        #expect(try await Self.ids(store, scope: .mailbox(10), flags: .init(unreadOnly: true)).count == 2)
        #expect(try await Self.ids(store, scope: .mailbox(99), flags: .init(unreadOnly: true)).isEmpty)
        #expect(
            try await Self.ids(store, scope: .account(1), .init(tags: ["work"])) == [
                c.ccMeBothTags, c.aliasStarredWork,
            ])
    }

    /// Equal timestamps fall back to the id, so the order and every window are stable.
    @Test func orderingIsDeterministicOnTies() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let ids = try await store.upsert(
            envelopes: (1...6).map {
                Seed.envelope(remoteId: $0, sentAt: 100, subject: "Same words", preview: "Same words")
            })
        let expected = Array(ids.reversed())
        #expect(try await Self.ids(store, flags: .init(unreadOnly: true)) == expected)
        #expect(try await Self.ids(store, text: "same words") == expected)
        var paged: [Int64] = []
        for offset in 0..<6 {
            paged += try await store.search(SearchQuery(text: "same"), limit: 1, offset: offset).map(\.id)
        }
        #expect(paged == expected)
    }

    @Test func aLiveFilterSearchDeliversAgainWhenAFlagChanges() async throws {
        let store = try MailStore.inMemory()
        let c = try await Self.corpus(store)
        var iterator = store.observeSearchRows(
            SearchQuery(text: "", flags: .init(starredOnly: true)), range: 0..<50
        ).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == [c.aliasStarredWork])
        try await store.write { db in
            try db.execute(sql: "UPDATE message SET isFlagged = 1 WHERE id = ?", arguments: [c.ccMeBothTags])
        }
        #expect(try await iterator.next()?.map(\.id) == [c.ccMeBothTags, c.aliasStarredWork])
    }

    // MARK: - Sheet options

    @Test func tagOptionsFollowTheScope() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        var all = store.observeSearchTags(scope: .all).makeAsyncIterator()
        #expect(try await all.next()?.map(\.imapLabel) == ["family", "work"])
        var mailbox = store.observeSearchTags(scope: .mailbox(10)).makeAsyncIterator()
        #expect(try await mailbox.next()?.map(\.displayName) == ["Family", "Work"])
        var other = store.observeSearchTags(scope: .account(99)).makeAsyncIterator()
        #expect(try await other.next()?.isEmpty == true)
    }

    @Test func addressSuggestionsArePrefixesOfSeenAddresses() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let alice = try await store.searchAddressSuggestions(prefix: "AL")
        #expect(alice.map(\.email) == ["alice@x.invalid"])
        #expect(alice.first?.label == "Alice")
        #expect(try await store.searchAddressSuggestions(prefix: "a").isEmpty)
        #expect(try await store.searchAddressSuggestions(prefix: "%").isEmpty)
        #expect(try await store.searchAddressSuggestions(prefix: "_l").isEmpty)
        // Most frequent first: dave twice, then the rest by address.
        #expect(try await store.searchAddressSuggestions(prefix: "da").map(\.email) == ["dave@x.invalid"])
        let me = try await store.searchAddressSuggestions(prefix: "me-")
        #expect(me.count == 1)
    }

    // MARK: - Query plans

    /// The address and date filters are served by indexes, not by scanning `message`.
    @Test func filtersUseIndexes() async throws {
        let store = try MailStore.inMemory()
        _ = try await Self.corpus(store)
        let fromPlan = try await Self.plan(store, SearchQuery(text: "", parameters: .init(from: "alice@x.invalid")))
        #expect(fromPlan.contains("idxAddressEmail"), "\(fromPlan)")
        let mailboxPlan = try await Self.plan(
            store, SearchQuery(text: "", scope: .mailbox(10), parameters: .init(sentAfter: 2000))
        )
        #expect(mailboxPlan.contains("idxMessageMailboxSent"), "\(mailboxPlan)")
        let suggestionPlan = try await store.read { db in
            try Row.fetchAll(
                db,
                sql: "EXPLAIN QUERY PLAN SELECT email FROM messageAddress WHERE email LIKE 'al%' ESCAPE '\\'"
            ).map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(suggestionPlan.contains("idxAddressEmail"), "\(suggestionPlan)")
    }

    static func plan(_ store: MailStore, _ query: SearchQuery) async throws -> String {
        let statement = try #require(SearchStatement(query: query, range: 0..<50))
        return try await store.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments)
                .map { $0["detail"] as String }
                .joined(separator: " | ")
        }
    }
}

/// What a combined filter search costs on a 10,000-message mirror, offline.
///
/// Measurements with a generous ceiling, on the same terms as ``SearchPerformanceTests``.
@Suite("Search filter performance", .serialized)
struct SearchFilterPerformanceTests {
    static let messageCount: Int64 = 10_000

    static func seed(_ store: MailStore) async throws {
        try await Seed.base(store)
        try await store.replaceAliases(
            [AliasRecord(accountId: 1, remoteId: 1, email: "alias@example.invalid", provisioned: false, rawJSON: "{}")],
            accountId: 1
        )
        let work = TagWrite(remoteId: 1, imapLabel: "work", displayName: "Work")
        var batch: [EnvelopeWrite] = []
        for id in Int64(1)...messageCount {
            var envelope = Seed.envelope(
                remoteId: id,
                sentAt: 1_600_000_000 + id * 60,
                subject: "Message \(id) about \(PerformanceTests.topics[Int(id) % PerformanceTests.topics.count])",
                preview: "The quick brown fox \(id) jumped over the lazy dog",
                isSeen: id % 3 == 0,
                addresses: [
                    EnvelopeAddress(kind: .from, email: "sender\(id % 50)@example.invalid", label: "Sender \(id % 50)"),
                    EnvelopeAddress(kind: .to, email: id % 2 == 0 ? "test@example.invalid" : "alias@example.invalid"),
                    EnvelopeAddress(kind: .cc, email: "cc\(id % 20)@example.invalid"),
                ]
            )
            envelope.hasAttachments = id % 7 == 0
            envelope.isImportant = id % 11 == 0
            envelope.isFlagged = id % 13 == 0
            envelope.mentionsMe = id % 17 == 0
            envelope.tags = id % 5 == 0 ? [work] : []
            batch.append(envelope)
            if batch.count == 1000 {
                try await store.upsert(envelopes: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try await store.upsert(envelopes: batch) }
    }

    @Test func combinedFilterSearchIsInstantAtTenThousandMessages() async throws {
        let store = try MailStore.inMemory()
        try await Self.seed(store)

        let shapes: [(String, SearchQuery)] = [
            (
                "text + unread + attachment + to me + from + cc + tag + dates, all mail",
                SearchQuery(
                    text: "hedgehogs",
                    scope: .all,
                    flags: .init(unreadOnly: true, withAttachmentsOnly: true, toMeOnly: true),
                    parameters: .init(
                        sentAfter: 1_600_000_000,
                        sentBefore: 1_600_000_000 + 9_000 * 60,
                        from: "sender35@example.invalid",
                        cc: ["cc15@example.invalid", "cc5@example.invalid"],
                        tags: ["work"]
                    )
                )
            ),
            (
                "text + subject + important + favorite, all mail",
                SearchQuery(
                    text: "fox",
                    flags: .init(starredOnly: true, importantOnly: true),
                    parameters: .init(subject: "roadmap")
                )
            ),
            (
                "filters only: unread + to me + tag + mentions, this mailbox",
                SearchQuery(
                    text: "",
                    scope: .mailbox(10),
                    flags: .init(unreadOnly: true, mentionsMeOnly: true, toMeOnly: true),
                    parameters: .init(tags: ["work"])
                )
            ),
            (
                "filters only: unread + attachment, all mail",
                SearchQuery(text: "", flags: .init(unreadOnly: true, withAttachmentsOnly: true))
            ),
            (
                "filters only: from one sender, all mail",
                SearchQuery(text: "", parameters: .init(from: "sender3@example.invalid"))
            ),
            (
                "filters only, sparse: important + mentions me, all mail",
                SearchQuery(text: "", flags: .init(importantOnly: true, mentionsMeOnly: true))
            ),
        ]
        for (name, query) in shapes {
            let results = try await store.search(query, limit: 50)
            let elapsed = try await PerformanceTests.best(of: 5) {
                _ = try await store.search(query, limit: 50)
            }
            reportMeasurement("10k \(name): \(results.count) hits, first 50 in \(String(format: "%.3f", elapsed)) ms")
            #expect(!results.isEmpty, "\(name) found nothing, so it measured nothing")
            #expect(elapsed < SearchPerformanceTests.budgetMilliseconds * 10, "\(name) took \(elapsed) ms")
        }
    }

    /// Every chip and toggle against a mirror of a real account, cross-checked against a
    /// plain count of the column it reads. Off by default; make the file as described on
    /// `SearchPerformanceTests.searchesARealMirror` and set `NCMAIL_LIVE_MIRROR_FILE`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR_FILE"] != nil))
    func filtersOnARealMirror() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR_FILE"])
        let store = try MailStore(url: URL(filePath: path))
        let shapes: [(String, SearchQuery.FlagFilter, String)] = [
            ("unread", .init(unreadOnly: true), "isSeen = 0"),
            ("has attachment", .init(withAttachmentsOnly: true), "hasAttachments = 1"),
            ("favorite", .init(starredOnly: true), "isFlagged = 1"),
            ("important", .init(importantOnly: true), "isImportant = 1"),
            ("mentions me", .init(mentionsMeOnly: true), "mentionsMe = 1"),
        ]
        for (name, flags, column) in shapes {
            let query = SearchQuery(text: "", flags: flags)
            let elapsed = try await PerformanceTests.best(of: 3) { _ = try await store.search(query, limit: 10_000) }
            let hits = try await store.search(query, limit: 10_000).count
            let expected = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE \(column)") ?? 0
            }
            reportMeasurement("live \(name): \(hits) hits in \(String(format: "%.3f", elapsed)) ms")
            #expect(hits == expected, "\(name)")
        }
        let toMe = try await store.search(SearchQuery(text: "", flags: .init(toMeOnly: true)), limit: 10_000).count
        let tagged = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT imapLabel FROM tag")
        }
        let taggedHits = try await store.search(SearchQuery(text: "", parameters: .init(tags: tagged)), limit: 10_000)
            .count
        reportMeasurement("live to me: \(toMe) hits; any of \(tagged.count) tags: \(taggedHits) hits")
    }
}
