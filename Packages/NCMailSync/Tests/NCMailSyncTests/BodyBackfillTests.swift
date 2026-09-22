// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// Stage 2: the account-wide body queue and the four etiquette rules around it.
///
/// The queue is seeded from the store rather than from a backfill, so each test says one
/// thing about the body stage instead of re-proving stages 0 and 1.
@Suite("Body backfill")
struct BodyBackfillTests {
    /// A mirror that already has envelopes and no bodies, which is exactly where stage 1
    /// leaves things.
    private func seededStore(messages: Int = 6) async throws -> (MailStore, MailStoreFixtures.SeedResult) {
        let store = try MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: messages, accountId: 1, mailboxId: 5)
        try await store.setEnvelopeCursor(1, complete: true, mailboxId: 5, lastSyncAt: 1)
        try await store.write { database in
            try database.execute(sql: "UPDATE mailbox SET lastPrimedAt = 1 WHERE id = 5")
        }
        return (store, seed)
    }

    /// Bootstrap and stage 1 answered with recordings that change nothing, so a run goes
    /// straight to stage 2 over the seeded rows.
    private func stubQuietStageOne(_ transport: FakeTransport) async throws {
        await transport.stub(MirrorTest.accountsRoute, with: .status(500))
        await transport.stub(MirrorTest.mailboxesRoute, with: .status(500))
        await transport.stub(MirrorTest.anySyncRoute, with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute, with: try .fixture("messages-inbox-page2.json"))
    }

    private func coordinator(
        store: MailStore,
        transport: FakeTransport,
        configuration: MirrorConfiguration,
        budget: MirrorBudget = MirrorBudget(limit: 4)
    ) throws -> MirrorCoordinator {
        MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: configuration,
            globalBudget: budget
        )
    }

    // MARK: - The happy path

    @Test("every message missing a body gets one, and the body, its attachments and the index land together")
    func bodiesAreBackfilled() async throws {
        let (store, seed) = try await seededStore()
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.start()
        await mirror.awaitCurrentRun()

        let progress = try await store.mirrorProgress(accountId: 1)
        #expect(progress.bodiesPresent == seed.messageIds.count)
        #expect(progress.isComplete)
        let newest = try #require(seed.messageIds.last)
        let stored = try #require(try await store.body(messageId: newest))
        #expect(stored.body.hasHtmlBody)
        #expect(stored.body.byteSize > 0)
    }

    @Test("newest first: recency is what people open")
    func theQueueIsNewestFirst() async throws {
        let (store, seed) = try await seededStore(messages: 4)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        // One worker, so the order the requests arrive in is the order the queue handed
        // them out rather than a race between two.
        let mirror = try coordinator(
            store: store,
            transport: transport,
            configuration: MirrorTest.configuration(bodyConcurrency: 1)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        let fetched = await transport.requestPaths
            .compactMap { path -> Int64? in
                guard path.hasSuffix("/body") else { return nil }
                return Int64(path.split(separator: "/").dropLast().last ?? "")
            }
        #expect(fetched == seed.messageIds.reversed())
    }

    @Test("an HTML message costs exactly two requests: the body and its sanitised fragment")
    func anHTMLMessageCostsTwoRequests() async throws {
        let (store, _) = try await seededStore(messages: 2)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        // The mirror skips the fragment when `hasHtmlBody` is false, and that branch has no
        // test because no recording has a plain-text body in it — editing one to say false
        // would test the editor, not the server. Asked of WS-14 in the report. Both recorded
        // bodies are HTML, so what is covered here is the two-request path.
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.start()
        await mirror.awaitCurrentRun()

        let bodies = await transport.requestPaths.filter { $0.hasSuffix("/body") }.count
        let fragments = await transport.requestPaths.filter { $0.hasSuffix("/html") }.count
        #expect(bodies == 2)
        #expect(fragments == 2)
    }

    @Test("a relaunch re-fetches no body it already has")
    func storedBodiesAreNotRefetched() async throws {
        let (store, seed) = try await seededStore(messages: 4)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let already = try #require(seed.messageIds.last)
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 1, plainBody: "kept"), for: already)

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.start()
        await mirror.awaitCurrentRun()

        let fetched = await transport.requestPaths.filter { $0.hasSuffix("/body") }
        #expect(fetched.count == seed.messageIds.count - 1)
        #expect(!fetched.contains { $0.contains("/\(already)/") })
        // And the stored copy was not overwritten by the backfill.
        let stored = try #require(try await store.body(messageId: already))
        #expect(stored.body.plainBody == "kept")
    }

    // MARK: - Failure paths

    @Test("a body that 404s is marked failed and the queue carries on")
    func aBodyThat404sDoesNotStallTheQueue() async throws {
        let (store, seed) = try await seededStore(messages: 3)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        let newest = try #require(seed.messageIds.last)
        await transport.stub(.pathContains("/messages/\(newest)/body"), with: .status(404))
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(
            store: store,
            transport: transport,
            configuration: MirrorTest.configuration(bodyConcurrency: 1)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        let record = try #require(try await store.message(id: newest))
        #expect(record.bodyState == .failed)
        let progress = try await store.mirrorProgress(accountId: 1)
        #expect(progress.bodiesFailed == 1)
        #expect(progress.bodiesPresent == seed.messageIds.count - 1)
        // Failed plus present covers everything, so the mirror reports complete rather than
        // spinning on a message the server no longer has.
        #expect(progress.isComplete)
    }

    @Test("a 403 on a body is a stale id, not a lost session")
    func aForbiddenBodyIsNotASignOut() async throws {
        let (store, seed) = try await seededStore(messages: 3)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        // Exactly what the live server answers for an id it will not show: 403 with `[]`.
        await transport.stub(MirrorTest.bodyRoute, with: .json("[]", status: 403))

        let mirror = try coordinator(
            store: store,
            transport: transport,
            configuration: MirrorTest.configuration(bodyConcurrency: 1)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        // Every message was given up on individually; nothing threw out of the run, and the
        // account is not marked failed.
        #expect(try await store.mirrorProgress(accountId: 1).bodiesFailed == seed.messageIds.count)
        let account = try #require(try await store.accounts().first)
        #expect(account.mirrorState != .failed)
    }

    @Test("a body that keeps erroring is given up on after three tries rather than retried forever")
    func aRepeatedlyFailingBodyIsGivenUp() async throws {
        let (store, seed) = try await seededStore(messages: 1)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        // A transport failure, which is retryable in principle and so is counted rather
        // than treated as "the message is gone".
        await transport.stub(MirrorTest.bodyRoute, with: .status(500))

        let mirror = try coordinator(
            store: store,
            transport: transport,
            configuration: MirrorTest.configuration(bodyConcurrency: 1)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        #expect(await transport.requestPaths.filter { $0.hasSuffix("/body") }.count == 3)
        let only = try #require(seed.messageIds.first)
        let record = try #require(try await store.message(id: only))
        #expect(record.bodyState == .failed)
    }

    @Test("a body whose html fragment 404s is still stored, from the copy the body carried")
    func aMissingFragmentDoesNotLoseTheBody() async throws {
        let (store, seed) = try await seededStore(messages: 1)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: .status(404))

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.start()
        await mirror.awaitCurrentRun()

        let only = try #require(seed.messageIds.first)
        let stored = try #require(try await store.body(messageId: only))
        #expect(stored.body.hasHtmlBody)
        #expect(stored.body.html?.isEmpty == false)
    }

    // MARK: - Etiquette

    @Test("never more than two body fetches in flight for one account")
    func concurrencyStaysInsideTheBudget() async throws {
        let (store, _) = try await seededStore(messages: 12)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(
            store: store,
            transport: transport,
            // One mailbox at a time in stage 1, so the peak this asserts on is stage 2's.
            configuration: MirrorTest.configuration(mailboxConcurrency: 1, bodyConcurrency: 2)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        #expect(await transport.peakInFlightCount <= 2)
    }

    @Test("a 429 halves body concurrency, and the cooldown expires on the clock rather than on a timer")
    func rateLimitingHalvesConcurrency() async throws {
        let (store, _) = try await seededStore(messages: 2)
        let transport = FakeTransport()
        let clock = TestClock()
        try await stubQuietStageOne(transport)
        await transport.stubSequence(
            MirrorTest.bodyRoute,
            [.retryAfter(30), try .fixture("message-body.json")]
        )
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let configuration = MirrorTest.configuration(clock: clock, bodyConcurrency: 2)
        let mirror = try coordinator(store: store, transport: transport, configuration: configuration)
        await mirror.start()
        await mirror.awaitCurrentRun()

        #expect(await mirror.bodyConcurrencyLimit == 1)

        clock.advance(by: configuration.throttleCooldownSeconds)
        await mirror.releaseThrottleIfExpired()
        #expect(await mirror.bodyConcurrencyLimit == 2)
    }

    @Test("Low Power Mode holds stage 2 and lets stage 1 finish")
    func lowPowerModeHoldsBodiesOnly() async throws {
        let store = try MailStore.inMemory()
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-initial.json"))
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page2.json"))
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))

        let mirror = try coordinator(
            store: store,
            transport: transport,
            configuration: MirrorTest.configuration(lowPowerMode: true)
        )
        await mirror.start()
        await mirror.awaitCurrentRun()

        // Stage 1 ran: the envelopes are here and every mirrored mailbox is enumerated.
        let recorded = try MirrorTest.recordedInbox()
        let progress = try await store.mirrorProgress(accountId: 1)
        #expect(progress.totalMessages == recorded.count)
        #expect(progress.mailboxesRemaining == 0)
        // Stage 2 did not.
        #expect(progress.bodiesPresent == 0)
        #expect(await transport.requestPaths.filter { $0.hasSuffix("/body") }.isEmpty)
        #expect(await mirror.pauseReason == .lowPowerMode)
    }

    @Test("an expensive network holds stage 2, and coming off it restarts the backfill")
    func anExpensiveNetworkHoldsBodies() async throws {
        let (store, seed) = try await seededStore(messages: 3)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.apply(conditions: MirrorConditions(isExpensive: true))
        await mirror.start()
        await mirror.awaitCurrentRun()
        #expect(try await store.mirrorProgress(accountId: 1).bodiesPresent == 0)

        await mirror.apply(conditions: MirrorConditions())
        await mirror.awaitCurrentRun()
        #expect(try await store.mirrorProgress(accountId: 1).bodiesPresent == seed.messageIds.count)
    }

    // MARK: - Etiquette rule 2: the user comes first

    @Test("prioritise fetches the message the user opened, even while the mirror is paused")
    func prioritiseWorksWhilePaused() async throws {
        let (store, seed) = try await seededStore(messages: 4)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))
        await transport.stub(MirrorTest.htmlRoute, with: try .fixture("message-html-plain.html"))

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.pause()

        let opened = try #require(seed.messageIds.first)
        await mirror.prioritise(messageId: opened)

        #expect(try await store.body(messageId: opened) != nil)
        // Nothing else was fetched: a paused mirror stays paused around the one message.
        #expect(await transport.requestPaths.filter { $0.hasSuffix("/body") }.count == 1)
        #expect(try await store.mirrorProgress(accountId: 1).bodiesPresent == 1)
    }

    @Test("prioritise does not re-fetch a body the mirror already has")
    func prioritiseSkipsAStoredBody() async throws {
        let (store, seed) = try await seededStore(messages: 2)
        let transport = FakeTransport()
        try await stubQuietStageOne(transport)
        await transport.stub(MirrorTest.bodyRoute, with: try .fixture("message-body.json"))

        let already = try #require(seed.messageIds.first)
        try await store.upsert(body: MessageBodyWrite(fetchedAt: 1, plainBody: "kept"), for: already)

        let mirror = try coordinator(store: store, transport: transport, configuration: MirrorTest.configuration())
        await mirror.prioritise(messageId: already)

        #expect(await transport.requestPaths.filter { $0.hasSuffix("/body") }.isEmpty)
    }
}
