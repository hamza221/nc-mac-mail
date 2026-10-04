// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// ADR-0067 in tests: `request(kind:key:)` returns before the network answers, the answer is
/// a row, a failure is a row only when there is no answer to keep, and offline is silent.
@Suite("Server result fetcher")
struct ServerResultFetcherTests {
    struct Fixture {
        let seeded: SyncTest.Seeded
        let loginId: Int64
        let transport: FakeTransport
        let fetcher: ServerResultFetcher
        let clock: TestClock
        /// A mirrored message and the server id every route is keyed by.
        let messageId: Int64
        let remoteId: Int64

        func payload(_ kind: ServerResultKind, _ key: String) async throws -> ServerResultPayload? {
            guard let row = try await seeded.store.serverResult(kind: kind.rawValue, key: key, loginId: loginId)
            else { return nil }
            return try ServerResultPayload(payloadJSON: row.payloadJSON)
        }

        var messageKey: String { ServerResultKind.messageKey(messageId) }

        /// A second fetcher over the same store whose requests matching `matcher` wait at a
        /// gate the test opens.
        func gated(holding matcher: RequestMatcher) throws -> (ServerResultFetcher, GatedTransport) {
            let gate = GatedTransport(inner: transport, holding: matcher)
            let clock = clock
            let fetcher = ServerResultFetcher(
                store: seeded.store,
                client: try ServerStateTest.client(gate),
                identity: MirrorTest.identity,
                now: { clock.now }
            )
            return (fetcher, gate)
        }
    }

    static func fixture() async throws -> Fixture {
        let seeded = try await SyncTest.seed(messages: Array(try Recorded.inbox().prefix(1)))
        let loginId = try #require(try await seeded.store.ensureLogin(MirrorTest.identity).id)
        let transport = FakeTransport()
        let clock = TestClock()
        let fetcher = ServerResultFetcher(
            store: seeded.store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity,
            now: { clock.now }
        )
        let (remoteId, messageId) = try #require(seeded.localByRemote.first)
        return Fixture(
            seeded: seeded,
            loginId: loginId,
            transport: transport,
            fetcher: fetcher,
            clock: clock,
            messageId: messageId,
            remoteId: remoteId
        )
    }

    // MARK: - Returning immediately

    @Test("request returns while the server is still thinking, and the row lands afterwards")
    func requestReturnsImmediately() async throws {
        let f = try await Self.fixture()
        let route = RequestMatcher.path("\(MirrorTest.apiRoot)/thread/\(f.remoteId)/summary")
        await f.transport.stub(route, with: try .fixture("thread-summary.json", status: 204))

        let (fetcher, gate) = try f.gated(holding: route)
        await fetcher.request(kind: .threadSummary, key: f.messageKey)
        await gate.waitForHeld()

        // The server has not answered, `request` has already returned, and the view is pending.
        #expect(try await f.payload(.threadSummary, f.messageKey) == nil)
        await gate.open()
        await fetcher.settle()

        // No LLM provider on the recorded server: 204, which is "nothing", not a failure.
        #expect(try await f.payload(.threadSummary, f.messageKey) == .empty)
    }

    // MARK: - Each kind

    @Test("smart replies: the recorded 204 is an empty row")
    func smartReply() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/messages/\(f.remoteId)/smartreply"),
            with: try .fixture("message-smartreply.json", status: 204))
        await f.fetcher.request(kind: .smartReply, key: f.messageKey)
        await f.fetcher.settle()
        #expect(try await f.payload(.smartReply, f.messageKey) == .empty)
    }

    @Test("itineraries: an empty extraction is an empty row")
    func itinerary() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/messages/\(f.remoteId)/itineraries"), with: try .fixture("message-itineraries.json"))
        await f.fetcher.request(kind: .itinerary, key: f.messageKey)
        await f.fetcher.settle()
        #expect(try await f.payload(.itinerary, f.messageKey) == .empty)
    }

    @Test("event data: {\"data\": null} is an empty row")
    func eventData() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/thread/\(f.remoteId)/eventdata"), with: try .fixture("thread-eventdata.json"))
        await f.fetcher.request(kind: .eventData, key: f.messageKey)
        await f.fetcher.settle()
        #expect(try await f.payload(.eventData, f.messageKey) == .empty)
    }

    @Test("translation of the stored body: the recorded 412 is a failed row")
    func translationWithoutProvider() async throws {
        let f = try await Self.fixture()
        let body = try JSONDecoder().decode(
            RawBacked<MessageBody>.self, from: try FixtureBytes.data("message-body.json"))
        try await f.seeded.store.upsert(
            body: try MirrorMapping.bodyWrite(body, html: nil, fetchedAt: 1),
            for: f.messageId
        )
        await f.transport.stub(
            .pathSuffix("/translation/translate"), with: try .fixture("translation-translate.json", status: 412))
        let key = ServerResultKind.translationKey(messageId: f.messageId, to: "de")

        await f.fetcher.request(kind: .translation, key: key)
        await f.fetcher.settle()

        guard case .failed? = try await f.payload(.translation, key) else {
            Issue.record("expected a failed row")
            return
        }
        let sent = try #require(await f.transport.requests.last?.httpBody)
        let fields = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(fields["toLanguage"] as? String == "de")
        #expect(fields["fromLanguage"] is NSNull)
        #expect((fields["text"] as? String)?.isEmpty == false)
    }

    @Test("translation before the body is mirrored fails without a request")
    func translationWithoutBody() async throws {
        let f = try await Self.fixture()
        let key = ServerResultKind.translationKey(messageId: f.messageId, to: "de")
        await f.fetcher.request(kind: .translation, key: key)
        await f.fetcher.settle()
        #expect(try await f.payload(.translation, key) == .failed("bodyNotMirrored"))
        #expect(await f.transport.sendCount == 0)
    }

    @Test("autocomplete supplements land in recipientSuggestion, in rank order")
    func autoComplete() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(.pathContains("/autoComplete"), with: try .fixture("autocomplete.json"))
        let recorded = try #require(
            try JSONSerialization.jsonObject(with: try FixtureBytes.data("autocomplete.json")) as? [Any])

        await f.fetcher.request(kind: .autoComplete, key: "ali")
        await f.fetcher.settle()

        let rows = try await f.seeded.store.recipientSuggestions(term: "ali", loginId: f.loginId)
        #expect(rows.count == recorded.count)
        #expect(rows.map(\.position) == Array(0..<recorded.count))
        #expect(try await f.payload(.autoComplete, "ali") == .ready(.object(["count": .int(recorded.count)])))
    }

    @Test("autocomplete failure leaves the previous suggestions")
    func autoCompleteFailure() async throws {
        let f = try await Self.fixture()
        await f.transport.stubSequence(
            .pathContains("/autoComplete"), [try .fixture("autocomplete.json"), .status(500)])
        await f.fetcher.request(kind: .autoComplete, key: "ali")
        await f.fetcher.settle()
        let before = try await f.seeded.store.recipientSuggestions(term: "ali", loginId: f.loginId)

        await f.fetcher.request(kind: .autoComplete, key: "ali", force: true)
        await f.fetcher.settle()

        #expect(try await f.seeded.store.recipientSuggestions(term: "ali", loginId: f.loginId) == before)
        guard case .ready? = try await f.payload(.autoComplete, "ali") else {
            Issue.record("the ready row must survive the failure")
            return
        }
    }

    @Test("quota on demand: a ready row keyed by the local account id")
    func quota() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/accounts/\(ServerStateTest.remoteAccountId)/quota"), with: try .fixture("account-quota.json"))
        let key = ServerResultKind.accountKey(f.seeded.accountId)
        await f.fetcher.request(kind: .quota, key: key)
        await f.fetcher.settle()
        #expect(try await f.payload(.quota, key) == .ready(.object(["usage": .int(0), "limit": .int(0)])))
    }

    @Test("follow-up on demand: one message, answered or not")
    func followUp() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(.pathSuffix("/follow-up/check-message-ids"), with: try .fixture("follow-up-check.json"))
        await f.fetcher.request(kind: .followUp, key: f.messageKey)
        await f.fetcher.settle()
        #expect(try await f.payload(.followUp, f.messageKey) == .ready(.object(["wasFollowedUp": .bool(false)])))
    }

    // MARK: - Failure, staleness, offline

    @Test("a failed request with nothing to keep is a failed row, so the view stops waiting")
    func failureWithoutAnswer() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(.pathSuffix("/thread/\(f.remoteId)/summary"), with: .status(500))
        await f.fetcher.request(kind: .threadSummary, key: f.messageKey)
        await f.fetcher.settle()
        #expect(try await f.payload(.threadSummary, f.messageKey) == .failed("server(status: 500)"))
    }

    @Test("a stale answer beats an error: a failure never overwrites a ready row")
    func failureKeepsAnswer() async throws {
        let f = try await Self.fixture()
        await f.transport.stubSequence(
            .pathSuffix("/accounts/\(ServerStateTest.remoteAccountId)/quota"),
            [try .fixture("account-quota.json"), .status(503)]
        )
        let key = ServerResultKind.accountKey(f.seeded.accountId)
        await f.fetcher.request(kind: .quota, key: key)
        await f.fetcher.settle()
        let before = try await f.seeded.store.serverResult(kind: "quota", key: key, loginId: f.loginId)

        await f.fetcher.request(kind: .quota, key: key, force: true)
        await f.fetcher.settle()

        #expect(await f.transport.sendCount == 2)
        #expect(try await f.seeded.store.serverResult(kind: "quota", key: key, loginId: f.loginId) == before)
    }

    @Test("a fresh row answers by itself; an expired one is asked again")
    func expiry() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/messages/\(f.remoteId)/itineraries"), with: try .fixture("message-itineraries.json"))
        await f.fetcher.request(kind: .itinerary, key: f.messageKey)
        await f.fetcher.settle()
        await f.fetcher.request(kind: .itinerary, key: f.messageKey)
        await f.fetcher.settle()
        #expect(await f.transport.sendCount == 1)

        f.clock.advance(by: ServerResultKind.itinerary.expiry)
        await f.fetcher.request(kind: .itinerary, key: f.messageKey)
        await f.fetcher.settle()
        #expect(await f.transport.sendCount == 2)
    }

    @Test("two requests for the same row while one is in flight send one request")
    func inFlightRequestsJoin() async throws {
        let f = try await Self.fixture()
        let route = RequestMatcher.pathSuffix("/thread/\(f.remoteId)/eventdata")
        await f.transport.stub(route, with: try .fixture("thread-eventdata.json"))
        let (fetcher, gate) = try f.gated(holding: route)
        await fetcher.request(kind: .eventData, key: f.messageKey)
        await gate.waitForHeld()
        await fetcher.request(kind: .eventData, key: f.messageKey)
        await gate.open()
        await fetcher.settle()
        #expect(await f.transport.sendCount == 1)
    }

    @Test("offline: nothing is sent and the last row stays as it was")
    func offline() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/accounts/\(ServerStateTest.remoteAccountId)/quota"), with: try .fixture("account-quota.json"))
        let key = ServerResultKind.accountKey(f.seeded.accountId)
        await f.fetcher.request(kind: .quota, key: key)
        await f.fetcher.settle()
        let before = try await f.seeded.store.serverResult(kind: "quota", key: key, loginId: f.loginId)

        await f.fetcher.apply(conditions: MirrorConditions(isOffline: true))
        await f.fetcher.request(kind: .quota, key: key, force: true)
        await f.fetcher.settle()

        #expect(await f.transport.sendCount == 1)
        #expect(try await f.seeded.store.serverResult(kind: "quota", key: key, loginId: f.loginId) == before)
    }

    @Test("a key that names no message is a failed row and no request")
    func unknownKey() async throws {
        let f = try await Self.fixture()
        await f.fetcher.request(kind: .smartReply, key: "999999")
        await f.fetcher.settle()
        #expect(try await f.payload(.smartReply, "999999") == .failed("unknownKey"))
        #expect(await f.transport.sendCount == 0)
    }
}

/// Envelope tags into `tag` and `messageTag` (WS-21; the store side is WS-18's v3 DAO).
@Suite("Envelope tags")
struct EnvelopeTagTests {
    @Test("a recorded envelope's tags are mirrored and attached to the message")
    func tagsAreMirrored() async throws {
        let rows = try Recorded.inbox()
        let tagged = try #require(rows.first { ($0["tags"] as? [String: Any])?.isEmpty == false })
        let seeded = try await SyncTest.seed(messages: [tagged])
        let messageId = try #require(seeded.localByRemote[Recorded.id(tagged)])
        let recorded = try #require(tagged["tags"] as? [String: [String: Any]])

        let tags = try await seeded.store.tags(messageId: messageId)

        #expect(Set(tags.map(\.imapLabel)) == Set(recorded.keys))
        #expect(Set(tags.map(\.remoteId)) == Set(recorded.values.compactMap { ($0["id"] as? NSNumber)?.int64Value }))
        #expect(try await seeded.store.tags(accountId: seeded.accountId).count == recorded.count)
    }

    @Test("a tag removed in the web client disappears from the message on the next sync")
    func removedTagIsCleared() async throws {
        let rows = try Recorded.inbox()
        let tagged = try #require(rows.first { ($0["tags"] as? [String: Any])?.isEmpty == false })
        let seeded = try await SyncTest.seed(messages: [tagged])
        let messageId = try #require(seeded.localByRemote[Recorded.id(tagged)])

        // The same recorded envelope with its tag taken off, as the next sync reports it.
        var untagged = tagged
        untagged["tags"] = [String: Any]()
        let envelope = try JSONDecoder().decode([RawBacked<Envelope>].self, from: try Recorded.data([untagged]))
        try await seeded.store.upsert(
            envelopes: try envelope.map {
                try MirrorMapping.envelopeWrite($0, accountId: seeded.accountId, mailboxId: seeded.inboxId, syncedAt: 2)
            }
        )

        #expect(try await seeded.store.tags(messageId: messageId).isEmpty)
        #expect(try await seeded.store.tags(accountId: seeded.accountId).isEmpty == false, "the tag itself stays")
    }
}
