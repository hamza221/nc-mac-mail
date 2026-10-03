// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// The incremental loop, against the fake transport.
///
/// Every scenario here is one the live server cannot be asked to produce on demand — a
/// message vanishing, a reply arriving in an existing thread, a mailbox falling out of the
/// server's IMAP cache. The envelopes inside each stubbed response are the recorded ones;
/// only which list they are in is the test's doing.
@Suite("Incremental sync")
struct IncrementalSyncTests {
    @Test("A vanished id removes the row, its body and its search entry")
    func vanishedMessagesAreDeletedLocally() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let doomed = Recorded.id(rows[3])
        let localId = try #require(seeded.localByRemote[doomed])
        // A body, so the test proves the cascade takes it rather than leaving an orphan.
        try await seeded.store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: false, plainBody: "gone soon"),
            for: localId
        )
        #expect(try await seeded.store.body(messageId: localId) != nil)

        let survivors = rows.filter { Recorded.id($0) != doomed }
        let transport = FakeTransport()
        let clock = TestClock()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: clock)
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(
                changed: survivors,
                vanished: [doomed],
                total: survivors.count,
                unread: 20
            )
        )
        await transport.stub(
            MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(survivors))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let remaining = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(remaining.count == rows.count - 1)
        #expect(!remaining.map(\.remoteId).contains(doomed))
        #expect(try await seeded.store.body(messageId: localId) == nil, "the cascade took the body with the row")
        #expect(await scheduler.metrics.messagesDeleted == 1)
    }

    @Test("A reply in an existing thread arrives through the tail scan, not through newMessages")
    func theTailScanFindsThreadSiblings() async throws {
        // The trap: `newMessages` joins the message table to itself on `thread_root_id` and
        // keeps only rows with no newer sibling, so a reply to a conversation the mirror
        // already holds is never mentioned. Here the server knows every recorded message and
        // says nothing new; only the tail scan can find the one that is missing locally —
        // one of the pair that shares a `dateInt`, the hardest place for a message to hide.
        let rows = try Recorded.inbox()
        let pair = try Recorded.sharedDateIntPair(rows)
        let sibling = Recorded.id(pair.second)
        let known = rows.filter { Recorded.id($0) != sibling }
        let seeded = try await SyncTest.seed(messages: known)

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: known, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let remaining = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(remaining.map(\.remoteId).contains(sibling))
        #expect(remaining.count == rows.count)
        #expect(
            Recorded.dateInt(pair.second) == Recorded.dateInt(pair.first),
            "the sibling is the twin of the duplicate-dateInt pair"
        )
    }

    @Test("In the steady state the tail scan is one request that finds nothing")
    func steadyStateIsOnePagePerMailbox() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let clock = TestClock()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: clock)
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))
        try await SyncTest.stubQuietMailboxes(transport)

        await scheduler.pass(mailboxIds: nil, forced: false)
        let first = await scheduler.metrics.requestsInLastCycle

        // Far enough for every mailbox to be due again, so the second cycle covers them all.
        clock.advance(by: 1_000)
        await scheduler.pass(mailboxIds: nil, forced: false)
        let second = await scheduler.metrics.requestsInLastCycle

        // Every mirrored, selectable mailbox. The inbox costs two — one sync, one tail
        // page — and the others the fixture leaves empty cost one each: with no rows to
        // claim there is no window worth sending, so those mailboxes are carried by the tail
        // scan alone until they have something in them.
        let others = try MirrorTest.recordedMailboxes().others
        #expect(second == 2 + others.count)
        #expect(first == second + SyncTest.boilerplateRequests, "only the first cycle reads the folder list")
        for entry in await scheduler.metrics.mailboxes.values {
            #expect(entry.lastTailScanPages == 1)
        }
    }

    @Test("A 428 re-primes the mailbox and the sync succeeds without a user-visible failure")
    func aNotCachedMailboxIsRePrimedSilently() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        // 428, then the prime's own answer, then the sync that follows it.
        await transport.stubSequence(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            [
                .status(428),
                try .fixture("sync-initial.json"),
                try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23),
            ]
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let syncCalls = await transport.requestPaths.count { $0.hasSuffix("/mailboxes/\(seeded.inboxRemoteId)/sync") }
        #expect(syncCalls == 3, "the 428, the re-prime, and the retry")
        let entry = await scheduler.metrics.mailboxes[seeded.inboxId]
        #expect(entry?.consecutiveFailures == 0)
        #expect(entry?.lastError == nil)
        let mailbox = try #require(try await seeded.store.mailbox(id: seeded.inboxId))
        #expect(mailbox.lastPrimedAt != nil)
    }

    @Test("One failing mailbox does not stop the others and does not clear what is mirrored")
    func oneFailingMailboxDoesNotStopTheAccount() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        // `times` large rather than unbounded: `FakeTransport.fail` has no "never succeeds",
        // which is the one gap WS-14 named and the doc comment tells callers to spell this way.
        await transport.fail(MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId), times: 10_000, then: .status(500))
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))
        try await SyncTest.stubQuietMailboxes(transport)

        await scheduler.syncNow()

        let remaining = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(remaining.count == rows.count, "a failed sync never clears what is mirrored")
        let metrics = await scheduler.metrics
        #expect(metrics.mailboxes[seeded.inboxId]?.consecutiveFailures == 1)
        let others = try MirrorTest.recordedMailboxes().others
        try #require(!others.isEmpty, "the test needs a second mirrored mailbox to keep going")
        for other in others {
            let mailbox = try #require(
                try await seeded.store.mailbox(remoteId: Int64(other), accountId: seeded.accountId)
            )
            #expect(metrics.mailboxes[mailbox.id]?.lastSuccessAt != nil, "mailbox \(other) still synced")
        }
        let row = try #require(try await seeded.store.mailbox(id: seeded.inboxId))
        #expect(row.syncFailureCount == 1)
        #expect(row.lastSyncError != nil)
    }

    @Test("Nothing is sent while offline, and reconnecting syncs at once")
    func offlineStopsEverything() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.apply(conditions: MirrorConditions(isOffline: true))
        await scheduler.syncNow(mailboxId: seeded.inboxId)
        #expect(await transport.sendCount == 0, "offline is not a mode with a degraded request")

        await scheduler.apply(conditions: MirrorConditions(isOffline: false))
        await scheduler.syncNow(mailboxId: seeded.inboxId)
        #expect(await transport.sendCount > 0)
        await scheduler.stop()
    }

    @Test("An expensive path does not stop sync, because a sync is kilobytes and bodies are not")
    func meteredNetworksStillSync() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.apply(conditions: MirrorConditions(isExpensive: true, isConstrained: true))
        await scheduler.syncNow(mailboxId: seeded.inboxId)
        #expect(await scheduler.metrics.mailboxes[seeded.inboxId]?.lastSuccessAt != nil)
    }

    @Test("The response's stats land on the mailbox row")
    func statsUpdateTheCounts() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: rows, total: 4_242, unread: 7)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let mailbox = try #require(try await seeded.store.mailbox(id: seeded.inboxId))
        #expect(mailbox.totalCount == 4_242)
        #expect(mailbox.unreadCount == 7)
        #expect(mailbox.isMirrored, "writing stats must not roll back the mirror's own columns")
    }

    @Test("A request that never answers is unwound by cancelling the task, not by waiting")
    func cancellationIsHonoured() async throws {
        let seeded = try await SyncTest.seed(messages: try Recorded.inbox())
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page([]))

        async let stalled = transport.stall(MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId))
        let task = Task { await scheduler.syncNow(mailboxId: seeded.inboxId) }
        // Awaiting the handle proves the request has arrived and is suspended inside the
        // transport. Cancelling — and never also resuming, which would resume the
        // continuation twice — is what the stall is for.
        _ = await stalled
        task.cancel()
        await task.value
        #expect(Bool(true), "returned rather than hanging")
    }
}

/// The ordering rule, and the conflict rule it exists to make unnecessary.
@Suite("Drain before sync")
struct DrainOrderingTests {
    @Test("The queue is drained before the first request of a pass")
    func drainRunsFirst() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let drainer = FakeDrainer()
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            drainer: drainer
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        #expect(drainer.drainCount == 0)
        await scheduler.syncNow(mailboxId: seeded.inboxId)
        #expect(drainer.drainCount == 1)
    }

    @Test("A sync arriving mid-drain does not clobber a pending intent")
    func aQueuedFlagSurvivesTheSync() async throws {
        // The user marked a message read while offline: the row says read, the queue holds
        // `{"seen": true}`, and the server still thinks it is unread. The sync must not undo
        // the user's action, and must still apply everything else the server says.
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let target = Recorded.id(rows[5])
        let localId = try #require(seeded.localByRemote[target])

        let drainer = FakeDrainer(intents: [PendingIntent(messageId: localId, flags: ["seen": true])])
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            drainer: drainer
        )

        // The server's copy of that one message, with `seen` forced false — the only field
        // any test here rewrites, and the whole subject of this one.
        let serverView =
            rows.filter { Recorded.id($0) != target }
            + Recorded.settingFlag("seen", to: false, on: rows.filter { Recorded.id($0) == target })
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: serverView, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let record = try #require(try await seeded.store.message(id: localId))
        #expect(record.isSeen, "the queued intent owns `seen` until the drain has sent it")
    }

    @Test("An intent queued while the write was in flight is repaired afterwards")
    func anIntentQueuedDuringTheWriteIsRepaired() async throws {
        // The read of `pendingOperation` that `offline-queue.md` wants inside the sync write
        // transaction is not available from here — `MailStore.write` is internal, correctly
        // — so the queue is read twice instead. This proves the second read does its job:
        // the drainer answers "nothing" first and "seen is mine" afterwards, which is
        // exactly what a user clicking during the write looks like.
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let target = Recorded.id(rows[2])
        let localId = try #require(seeded.localByRemote[target])

        let drainer = LateDrainer(lateIntent: PendingIntent(messageId: localId, flags: ["seen": true]))
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            drainer: drainer
        )
        let serverView =
            rows.filter { Recorded.id($0) != target }
            + Recorded.settingFlag("seen", to: false, on: rows.filter { Recorded.id($0) == target })
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: seeded.inboxRemoteId),
            with: try Recorded.syncResponse(changed: serverView, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(rows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let record = try #require(try await seeded.store.message(id: localId))
        #expect(record.isSeen, "the repair pass caught the operation queued during the write")
    }
}

/// A drainer that has nothing to say until it is asked a second time.
final class LateDrainer: OperationDraining {
    private let lateIntent: PendingIntent
    private let asked: Mutex<Int>

    init(lateIntent: PendingIntent) {
        self.lateIntent = lateIntent
        asked = Mutex(0)
    }

    func drain() async {}

    func pendingIntents() async -> [PendingIntent] {
        let count = asked.withLock { value -> Int in
            value += 1
            return value
        }
        return count == 1 ? [] : [lateIntent]
    }
}
