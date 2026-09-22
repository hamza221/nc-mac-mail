// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// Bootstrap, stage 0 and stage 1, against recorded payloads and an in-memory mirror.
///
/// Every assertion is about what ended up in the database, because that is the only thing
/// the rest of the application can see: the coordinator hands a view nothing.
@Suite("Mirror coordinator")
struct MirrorCoordinatorTests {
    // MARK: - Discovery

    @Test("discoverAccounts gives every account of one login a local id, scoped to that login")
    func discoveryScopesAccountsToTheLogin() async throws {
        let store = try MailStore.inMemory()
        let transport = FakeTransport()
        await transport.stub(MirrorTest.accountsRoute, with: try .fixture("accounts.json"))

        let first = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity
        )
        #expect(first.count == 3)
        // The ids the live recording carries, not consecutive ones.
        #expect(first.map(\.remoteId).sorted() == [1, 17, 18])
        #expect(first.allSatisfy { $0.identity == MirrorTest.identity })

        // Running it again is a refresh, not three more accounts.
        let again = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity
        )
        #expect(again.map(\.id) == first.map(\.id))
        #expect(try await store.accounts().count == 3)

        // The same three server ids from a second instance are three more accounts, which
        // is ADR-0033's whole point. The live instance has one account, so this is the only
        // place the collision can be shown.
        let elsewhere = ServerIdentity(serverURL: "https://other.example.invalid/", loginName: "alice")
        let second = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: try MirrorTest.client(transport),
            identity: elsewhere
        )
        #expect(Set(second.map(\.id)).isDisjoint(with: first.map(\.id)))
        #expect(try await store.accounts().count == 6)
        #expect(try await store.accounts(identity: elsewhere).count == 3)
    }

    @Test("a coordinator for an account the mirror has no row for stops rather than guessing")
    func aCoordinatorWithoutItsAccountRowStops() async throws {
        let store = try MailStore.inMemory()
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 99,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        // Nothing was asked for and nothing was written: without the row there is no server
        // id to ask about.
        #expect(await transport.requests.isEmpty)
        #expect(try await store.accounts().isEmpty)
    }

    // MARK: - Bootstrap

    @Test("bootstrap stores the accounts and the folder list, and mirrors only the subscribed folders")
    func bootstrapRespectsSubscription() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        await transport.stub(MirrorTest.anySyncRoute, with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute, with: try .fixture("messages-inbox-page2.json"))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        #expect(try await store.accounts().count == 3)
        let mailboxes = try await store.mailboxes(accountId: 1)
        #expect(mailboxes.count == 7)
        #expect(mailboxes.filter(\.isMirrored).map(\.remoteId).sorted() == [3, 4, 5, 6, 7])

        // ADR-0007: the two unsubscribed folders are in the sidebar and nowhere near the
        // backfill. Neither was primed and neither was enumerated.
        let urls = await transport.requestURLs
        #expect(!urls.contains { $0.contains("/mailboxes/1/sync") })
        #expect(!urls.contains { $0.contains("/mailboxes/2/sync") })
        #expect(!urls.contains { $0.contains("mailboxId=1&") })
        #expect(!urls.contains { $0.contains("mailboxId=2&") })
    }

    @Test("a failed folder refresh does not stop the backfill of what is already mirrored")
    func bootstrapToleratesAFailedRefresh() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        await transport.stub(MirrorTest.accountsRoute, with: .status(500))
        await transport.stub(MirrorTest.mailboxesRoute, with: .status(500))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        // Nothing to mirror yet, and no crash: a relaunch with no network is not an error.
        #expect(try await store.mailboxes(accountId: 1).isEmpty)
    }

    // MARK: - Stage 0

    @Test("priming stores the envelopes it gets free, and stamps lastPrimedAt")
    func primingStoresItsEnvelopes() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        let clock = TestClock()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-initial.json"))
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page1.json"))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration(clock: clock)
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(inbox.lastPrimedAt == clock.now)
        // Measured on the live server and reproduced here: with an empty `ids` the sync
        // route answers from `findAllIds`, so all 95 come back rather than 87 thread heads.
        let recorded = try MirrorTest.recordedInbox()
        #expect(try await store.counts().totalMessages == recorded.count)
    }

    @Test("a 202 that resolves on the third try is invisible to everything downstream")
    func primingRetriesA202() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stubSequence(
            MirrorTest.syncRoute(mailboxId: 5),
            [.status(202), .status(202), try .fixture("sync-initial.json")]
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page2.json"))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let syncCalls = await transport.requestPaths.filter { $0.hasSuffix("/mailboxes/5/sync") }
        #expect(syncCalls.count == 3)
        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(inbox.lastPrimedAt != nil)
        #expect(inbox.envelopesComplete)
        // No user-visible failure was recorded for a mailbox that simply took three asks.
        #expect(inbox.syncFailureCount == 0)
        #expect(inbox.lastSyncError == nil)
    }

    @Test("a 428 is answered by priming again, and the mailbox is mirrored without a mark against it")
    func primingAnswersA428() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stubSequence(
            MirrorTest.syncRoute(mailboxId: 5),
            [.status(428), try .fixture("sync-initial.json")]
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page1.json"))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(inbox.lastPrimedAt != nil)
        #expect(inbox.envelopesComplete)
        #expect(inbox.syncFailureCount == 0)
    }

    @Test("a mailbox that never finishes priming is left behind, and the other four are not")
    func oneStuckMailboxDoesNotBlockTheAccount() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: .status(202))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration(mailboxConcurrency: 2)
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let mailboxes = try await store.mailboxes(accountId: 1)
        let inbox = try #require(mailboxes.first { $0.id == 5 })
        #expect(inbox.syncFailureCount == 1)
        #expect(inbox.lastSyncError?.contains("primingDidNotFinish") == true)
        #expect(inbox.envelopesComplete == false)
        // Everything else finished. One slow folder is one slow folder.
        #expect(mailboxes.filter { [3, 4, 6, 7].contains($0.id) }.allSatisfy { $0.envelopesComplete })
    }

    // MARK: - Stage 1

    @Test("pages carry the cursor the previous page ended on, and a short page ends the mailbox")
    func enumerationPagesWithTheCursor() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        let recorded = try MirrorTest.recordedInbox()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-incremental.json"))
        await transport.stubSequence(
            MirrorTest.messagesRoute(mailboxId: 5),
            [try .fixture("messages-inbox-page1.json"), try .fixture("messages-inbox-page2.json")]
        )
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            // The recorded page holds 95, so 95 is what makes it a full page and forces a
            // second request. The real page size is 100; this is the same code path.
            configuration: MirrorTest.configuration(envelopePageSize: recorded.count)
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inboxPages = await transport.requestURLs.filter { $0.contains("mailboxId=5&") }
        #expect(inboxPages.count == 2)
        #expect(inboxPages.first?.contains("cursor=") == false)
        // Exclusive, verified against the live server: passing the oldest `dateInt` of a
        // page returns messages strictly older than it.
        #expect(inboxPages.last?.contains("cursor=\(recorded.oldestDateInt + 1)") == true)
        #expect(inboxPages.allSatisfy { $0.contains("view=singleton") })

        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(inbox.envelopeCursor == recorded.oldestDateInt + 1)
        #expect(inbox.envelopesComplete)
        #expect(try await store.counts().totalMessages == recorded.count)
    }

    @Test("the cursor overlaps by one second, so two messages sharing a dateInt cannot straddle a page")
    func theCursorOverlapsThePageBoundary() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        let recorded = try MirrorTest.recordedInbox()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-incremental.json"))
        await transport.stubSequence(
            MirrorTest.messagesRoute(mailboxId: 5),
            [try .fixture("messages-inbox-page1.json"), try .fixture("messages-inbox-page2.json")]
        )
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration(envelopePageSize: recorded.count)
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        // The server's cursor is strictly exclusive, measured on the live instance: asking
        // with a page's oldest `dateInt` returns messages older than it and never it. The
        // live inbox carries two messages at 1778515439, so a cursor of exactly the oldest
        // value drops the second one the moment the boundary falls between them. Asking for
        // one past it re-reads the boundary message instead, whose upsert is a no-op.
        let asked = await transport.requestURLs.filter { $0.contains("mailboxId=5&") }
        #expect(asked.last?.contains("cursor=\(recorded.oldestDateInt + 1)") == true)
        #expect(asked.last?.contains("cursor=\(recorded.oldestDateInt)&") == false)

        // The recording does contain such a pair, and both are mirrored.
        #expect(try await store.message(remoteId: 44) != nil)
        #expect(try await store.message(remoteId: 45) != nil)
    }

    @Test("a relaunch mid-stage-1 resumes at the stored cursor and re-fetches at most one page")
    func enumerationResumesFromTheStoredCursor() async throws {
        let store = try MailStore.inMemory()
        let transport = FakeTransport()
        let recorded = try MirrorTest.recordedInbox()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page2.json"))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        // What the previous run committed before it was killed: a cursor, and a mailbox
        // already primed.
        let accountId = try await MirrorTest.mirroredAccount(store)
        let mailboxes = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: accountId,
                    remoteId: 5,
                    name: "INBOX",
                    displayName: "INBOX",
                    isSubscribed: true
                )
            ],
            accountId: accountId
        )
        let inboxId = try #require(mailboxes.first).id
        try await store.setEnvelopeCursor(recorded.oldestDateInt, complete: false, mailboxId: inboxId, lastSyncAt: 1)
        try await store.setLastPrimedAt(1, mailboxId: inboxId)

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inboxPages = await transport.requestURLs.filter { $0.contains("mailboxId=5&") }
        #expect(inboxPages.count == 1)
        #expect(inboxPages.first?.contains("cursor=\(recorded.oldestDateInt)") == true)
        // Already primed, so stage 0 was not repeated.
        #expect(await transport.requestPaths.filter { $0.hasSuffix("/mailboxes/5/sync") }.isEmpty)
    }

    @Test("a page is committed before its cursor moves, so a failure mid-mailbox loses nothing")
    func envelopesLandBeforeTheCursor() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        let recorded = try MirrorTest.recordedInbox()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-incremental.json"))
        // A full page, then the network goes away for good.
        await transport.stubSequence(
            MirrorTest.messagesRoute(mailboxId: 5),
            [try .fixture("messages-inbox-page1.json"), .status(500)]
        )
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration(envelopePageSize: recorded.count)
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(try await store.counts().totalMessages == recorded.count)
        #expect(inbox.envelopeCursor == recorded.oldestDateInt + 1)
        #expect(inbox.envelopesComplete == false)
        #expect(inbox.syncFailureCount == 1)
    }

    @Test("a 428 on a page re-primes and retries that page rather than failing the mailbox")
    func aPageThatFallsOutOfTheServerCacheIsReprimed() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-incremental.json"))
        await transport.stubSequence(
            MirrorTest.messagesRoute(mailboxId: 5),
            [.status(428), try .fixture("messages-inbox-page1.json")]
        )
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        // Primed once at the start of the mailbox, once more when the page 428'd.
        #expect(await transport.requestPaths.filter { $0.hasSuffix("/mailboxes/5/sync") }.count == 2)
        let inbox = try #require(try await store.mailbox(remoteId: 5))
        #expect(inbox.envelopesComplete)
        #expect(inbox.syncFailureCount == 0)
    }

    // MARK: - Pausing

    @Test("pause persists, and a coordinator built afterwards does not start on its own")
    func pausePersistsAcrossRelaunch() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        await transport.stub(MirrorTest.anySyncRoute, with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute, with: try .fixture("messages-inbox-page2.json"))

        let first = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await first.pause()
        #expect(await first.pauseReason == .userRequested)

        let relaunched = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await relaunched.start()
        await relaunched.awaitCurrentRun()
        #expect(await transport.sendCount == 0)
        #expect(await relaunched.pauseReason == .userRequested)

        await relaunched.resume()
        await relaunched.awaitCurrentRun()
        #expect(await transport.sendCount > 0)
        #expect(await relaunched.pauseReason == nil)
    }

    @Test("offline stops the mirror without an error, and reconnecting resumes it")
    func offlinePausesAndReconnectingResumes() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        await transport.stub(MirrorTest.anySyncRoute, with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute, with: try .fixture("messages-inbox-page2.json"))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.apply(conditions: MirrorConditions(isOffline: true))
        await coordinator.start()
        await coordinator.awaitCurrentRun()
        #expect(await transport.sendCount == 0)
        #expect(await coordinator.pauseReason == .offline)

        await coordinator.apply(conditions: MirrorConditions(isOffline: false))
        await coordinator.awaitCurrentRun()
        #expect(await coordinator.pauseReason == nil)
        #expect(try await store.mailboxes(accountId: 1).count == 7)
    }

    @Test("cancelling a run in flight unwinds promptly instead of finishing the mailbox")
    func pauseCancelsAnInFlightRequest() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        try await MirrorTest.stubBootstrap(transport)
        await transport.stub(MirrorTest.anySyncRoute, with: try .fixture("sync-incremental.json"))
        await transport.stub(MirrorTest.messagesRoute, with: try .fixture("messages-inbox-page2.json"))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        // Catch the very first request and hold it there.
        async let stalled = transport.stall(MirrorTest.accountsRoute)
        // One hop, so the stall is registered before the run task is even created. The run
        // then reads `meta` from the database before its first request, which is several
        // more hops on top.
        await Task.yield()
        await coordinator.start()
        _ = await stalled

        // `pause` cancels and waits; the stalled send throws `CancellationError` rather
        // than hanging, so this returns without the test ever resuming the continuation.
        await coordinator.pause()
        #expect(await coordinator.pauseReason == .userRequested)
        #expect(try await store.mailboxes(accountId: 1).isEmpty)
    }

    // MARK: - Progress

    @Test("progress is published from the rows, and reports counts rather than a percentage")
    func progressIsPublished() async throws {
        let store = try MailStore.inMemory()
        _ = try await MirrorTest.mirroredAccount(store)
        let transport = FakeTransport()
        let recorded = try MirrorTest.recordedInbox()
        try await MirrorTest.stubBootstrap(transport)
        try await MirrorTest.stubQuietMailboxes(transport, except: 5)
        await transport.stub(MirrorTest.syncRoute(mailboxId: 5), with: try .fixture("sync-initial.json"))
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try .fixture("messages-inbox-page2.json"))
        await transport.stub(MirrorTest.bodyRoute, with: .status(404))

        let coordinator = MirrorCoordinator(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: 1,
            configuration: MirrorTest.configuration()
        )
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        // The stream buffers the newest element only, so after the run this reads the last
        // snapshot the coordinator published without racing it.
        var iterator = coordinator.progress.makeAsyncIterator()
        let last = try #require(await iterator.next())
        #expect(last.totalMessages == recorded.count)
        #expect(last.mailboxesRemaining == 0)
        // Recomputed, not tallied: the same numbers come straight back out of the database.
        #expect(last == (try await store.mirrorProgress(accountId: 1)))
    }
}
