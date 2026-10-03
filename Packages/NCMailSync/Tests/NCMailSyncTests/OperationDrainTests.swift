// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// What the drainer does with each answer the server can give, against the real schema and
/// `FakeTransport`.
///
/// No test here sleeps or reads the wall clock. A backoff is a column, so "two seconds
/// later" is `clock.advance(by: 2)`.
@Suite("Operation drain")
struct OperationDrainTests {
    @Test func reconnectingDrainsInOrderAndEmptiesTheQueue() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)

        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[1]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(.delete(messageIds: [fixture.messageIds[2]]), accountId: fixture.accountId)

        await fixture.drainer.drain()

        let paths = await fixture.transport.requests.compactMap { $0.url?.path }
        #expect(paths.count == 3)
        #expect(paths[0].hasSuffix("/messages/1/flags"))
        #expect(paths[1].hasSuffix("/messages/2/move"))
        #expect(paths[2].hasSuffix("/messages/3"))
        #expect(try await fixture.rows().isEmpty)
        // The mirror is untouched by a successful drain: the change was already there.
        #expect(try await fixture.message(0).isSeen)
        #expect(try await fixture.message(1).mailboxId == fixture.archiveId)
    }

    @Test func starUnstarStarSendsOneRequestWithTheFinalState() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        let messageId = fixture.messageIds[0]

        for value in [true, false, true] {
            try await fixture.queue.perform(
                .setFlags(messageIds: [messageId], flags: ["flagged": value]),
                accountId: fixture.accountId
            )
        }
        #expect(try await fixture.rows().count == 3)

        await fixture.drainer.drain()

        #expect(await fixture.transport.sendCount == 1)
        let body = try QueueTest.body(try #require(await fixture.transport.requests.first))
        #expect(try #require(body["flags"] as? [String: Any])["flagged"] as? Bool == true)
        #expect(try await fixture.rows().isEmpty)
        #expect(try await fixture.message(0).isFlagged)
    }

    @Test func aMessageDeletedElsewhereDropsTheOperationAndTheLocalRow() async throws {
        let fixture = try await QueueTest.make()
        await fixture.transport.stub(QueueTest.flagsRoute, with: .status(404))
        let messageId = fixture.messageIds[0]

        try await fixture.queue.perform(
            .setFlags(messageIds: [messageId], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        // Quietly: no retry, no row, no message, and nothing for the user to dismiss.
        #expect(try await fixture.rows().isEmpty)
        #expect(try await fixture.store.message(id: messageId) == nil)
        #expect(await fixture.drainer.summary().failing == 0)
    }

    @Test func aForbiddenOperationIsDroppedAndTheAccountReRead() async throws {
        let fixture = try await QueueTest.make()
        // What the Mail app answers for an id the user may not see, which includes an id
        // that no longer exists. A bare 403 is not a lost session.
        await fixture.transport.stub(QueueTest.moveRoute, with: .json("[]", status: 403))

        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[0]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.accountRefreshes.all == [fixture.accountId])
        // The local message stays. Sync decides what is true about it, not the drainer.
        #expect(try await fixture.store.message(id: fixture.messageIds[0]) != nil)
    }

    @Test func aConflictDropsTheOperationAndForcesASyncOfTheSourceMailbox() async throws {
        let fixture = try await QueueTest.make()
        await fixture.transport.stub(QueueTest.moveRoute, with: .status(409))

        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[0]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        #expect(try await fixture.rows().isEmpty)
        #expect(fixture.forcedSyncs.all == [fixture.inboxId])
    }

    @Test func rateLimitingWaitsWithoutCountingAFailure() async throws {
        let fixture = try await QueueTest.make()
        await fixture.transport.stub(QueueTest.flagsRoute, with: .retryAfter(30))

        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        let row = try #require(try await fixture.rows().first)
        #expect(row.attempts == 0, "a busy server must never push an operation towards the indicator")
        #expect(row.nextAttemptAt == fixture.clock.now + 30)
        #expect(row.state == .pending)
        #expect(await fixture.transport.sendCount == 1)
    }

    @Test func fiveFailuresSurfaceOnceAndRetryNowWorks() async throws {
        let fixture = try await QueueTest.make()
        // Five failures then success, so "Retry now" has something to succeed at. A second
        // `stub` would never fire: `FakeTransport` takes the first matcher that matches.
        await fixture.transport.stubSequence(
            QueueTest.flagsRoute,
            Array(repeating: .status(500), count: 5) + [.status(200)]
        )

        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )

        let expectedBackoff: [Int64] = [2, 8, 30, 120, 600]
        for (index, wait) in expectedBackoff.enumerated() {
            await fixture.drainer.drain()
            let row = try #require(try await fixture.rows().first)
            #expect(row.attempts == index + 1)
            #expect(row.nextAttemptAt == fixture.clock.now + wait)
            // Nothing is visible until the fifth. Retrying is normal.
            #expect(await fixture.drainer.summary().failing == (index == 4 ? 1 : 0))
            fixture.clock.advance(by: wait)
        }

        let summary = await fixture.drainer.summary()
        #expect(summary.queued == 1)
        #expect(summary.failures.count == 1, "one aggregate entry, never one per attempt")
        #expect(summary.failures.first?.attempts == 5)

        await fixture.drainer.retryAll()

        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.drainer.summary().failing == 0)
    }

    @Test func fiveFailuresAcrossFortyMessagesAreStillOneIndicator() async throws {
        let fixture = try await QueueTest.make(messages: 40)
        await fixture.transport.stub(QueueTest.moveRoute, with: .status(500))

        try await fixture.queue.perform(
            .move(messageIds: fixture.messageIds, destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        for wait in [Int64(2), 8, 30, 120, 600] {
            await fixture.drainer.drain()
            fixture.clock.advance(by: wait)
        }

        let summary = await fixture.drainer.summary()
        #expect(summary.failing == 40)
        // Forty entries in one popover behind one indicator. `AppStatus.pendingFailures` is
        // a number, and `ux-spec.md` allows exactly one line in the sidebar footer.
        #expect(summary.failures.count == 40)
    }

    @Test func theMoveBodyNamesDestFolderIdAndTheThreadBodyNamesDestMailboxId() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        let rootId = try #require(try await fixture.message(0).threadRootId)

        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[0]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()
        try await fixture.queue.perform(
            .moveThread(rootId: rootId, destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        let requests = await fixture.transport.requests
        #expect(requests.count == 2)
        let message = try QueueTest.body(requests[0])
        let thread = try QueueTest.body(requests[1])
        // Same concept, same value, two spellings. Upstream's, and it has already cost
        // someone an afternoon.
        #expect(message["destFolderId"] as? Int64 == QueueTest.remoteArchive)
        #expect(message["destMailboxId"] == nil)
        #expect(thread["destMailboxId"] as? Int64 == QueueTest.remoteArchive)
        #expect(thread["destFolderId"] == nil)
        // And the id in the body is the server's, not the mirror's (ADR-0033).
        #expect(QueueTest.remoteArchive != fixture.archiveId)
    }

    @Test func discardRevertsToExactlyThePreActionState() async throws {
        let fixture = try await QueueTest.make()
        let messageId = fixture.messageIds[0]
        let before = try await fixture.message(0)

        try await fixture.queue.perform(
            .setFlags(messageIds: [messageId], flags: ["seen": !before.isSeen, "flagged": !before.isFlagged]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .move(messageIds: [messageId], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        let rows = try await fixture.rows()
        #expect(rows.count == 2)

        for row in rows {
            await fixture.drainer.discard(operationId: try #require(row.id))
        }

        let after = try await fixture.message(0)
        #expect(after.isSeen == before.isSeen)
        #expect(after.isFlagged == before.isFlagged)
        #expect(after.mailboxId == before.mailboxId)
        #expect(try await fixture.rows().isEmpty)
        #expect(await fixture.transport.sendCount == 0)
    }

    @Test func discardingAFoldRevertsTheWholeFold() async throws {
        let fixture = try await QueueTest.make()
        let messageId = fixture.messageIds[0]
        let before = try await fixture.message(0)

        for value in [true, false, true] {
            try await fixture.queue.perform(
                .setFlags(messageIds: [messageId], flags: ["flagged": value]),
                accountId: fixture.accountId
            )
        }
        // The popover shows one entry, whose id is the oldest row of the fold.
        await fixture.drainer.discard(operationId: try #require(try await fixture.rows().first?.id))

        #expect(try await fixture.message(0).isFlagged == before.isFlagged)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func aRowOrphanedByADeletedMessageIsCleanedUpByTheDrain() async throws {
        let fixture = try await QueueTest.make()
        await fixture.transport.stub(QueueTest.flagsRoute, with: .status(404))
        let messageId = fixture.messageIds[0]

        try await fixture.queue.perform(
            .setFlags(messageIds: [messageId], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        // A sync finds the message gone server-side and deletes the row. `messageId` has no
        // foreign key, so the queue row is left behind pointing at nothing.
        try await fixture.store.deleteMessages(ids: [messageId])
        #expect(try await fixture.rows().count == 1)

        await fixture.drainer.drain()

        // The request still went out — the row carries the server's id, not a pointer to a
        // local row — and the 404 took the orphan with it.
        #expect(await fixture.transport.sendCount == 1)
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func discardingEverythingRevertsEveryQueuedChange() async throws {
        let fixture = try await QueueTest.make()
        let before = try await fixture.message(0)

        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["flagged": !before.isFlagged]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[0]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[1]], destinationMailboxId: fixture.junkId),
            accountId: fixture.accountId
        )

        await fixture.drainer.discardAll()

        #expect(try await fixture.rows().isEmpty)
        let after = try await fixture.message(0)
        #expect(after.isFlagged == before.isFlagged)
        #expect(after.mailboxId == before.mailboxId)
        #expect(try await fixture.message(1).mailboxId == fixture.inboxId)
        #expect(await fixture.transport.sendCount == 0)
    }

    @Test func pendingIntentsAnswerTheCollapsedFinalStatePerMessage() async throws {
        let fixture = try await QueueTest.make()
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["flagged": true]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["flagged": false, "seen": true]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .move(messageIds: [fixture.messageIds[1]], destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )

        let intents = await fixture.drainer.pendingIntents()
        #expect(intents.count == 1, "a move sets no flag, so it masks nothing")
        #expect(intents.first?.messageId == fixture.messageIds[0])
        #expect(intents.first?.flags == ["flagged": false, "seen": true])
    }

    @Test func aDrainedQueueHoldsNoIntentsAtAll() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        // The reason the drain runs before sync: the common case has no conflict in it.
        #expect(await fixture.drainer.pendingIntents().isEmpty)
    }

    @Test func offlineLeavesEverythingQueuedAndStopsThePass() async throws {
        let fixture = try await QueueTest.make()
        // Never succeeds. `FakeTransport.fail` counts calls, so this is how it is spelled.
        await fixture.transport.fail(QueueTest.flagsRoute, times: 10_000, then: .status(200))

        try await fixture.queue.perform(
            .setFlags(messageIds: Array(fixture.messageIds.prefix(3)), flags: ["seen": true]),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        // One attempt, not three: with no network the other two would fail the same way and
        // burn three attempts' worth of backoff on one outage.
        #expect(await fixture.transport.sendCount == 1)
        let rows = try await fixture.rows()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.state == .pending })
        #expect(rows.first?.attempts == 1)
    }

    @Test func aFiveHundredOnOneMessageDoesNotBlockTheNext() async throws {
        let fixture = try await QueueTest.make()
        await fixture.transport.stubSequence(QueueTest.flagsRoute, [.status(500), .status(200), .status(200)])

        try await fixture.queue.perform(
            .setFlags(messageIds: Array(fixture.messageIds.prefix(3)), flags: ["seen": true]),
            accountId: fixture.accountId
        )
        await fixture.drainer.drain()

        #expect(await fixture.transport.sendCount == 3)
        let rows = try await fixture.rows()
        #expect(rows.count == 1, "the two that worked are gone; the one that failed is waiting")
        #expect(rows.first?.attempts == 1)
    }

    @Test func aCancelledDrainStopsWithoutCountingAFailure() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )

        async let handle = fixture.transport.stall(QueueTest.flagsRoute)
        let drain = Task { await fixture.drainer.drain() }
        _ = await handle
        drain.cancel()
        await drain.value

        let row = try #require(try await fixture.rows().first)
        #expect(row.state == .pending)
        #expect(row.attempts == 0)
    }

    @Test func theSummaryIsPublishedToWhoeverIsWatching() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )

        var iterator = fixture.drainer.pendingCount.makeAsyncIterator()
        // Subscribing yields the current summary straight away, so a view drawn late is not
        // blank until something changes. Awaiting it here is also what makes the rest of
        // this test ordered rather than racy.
        #expect(await iterator.next()?.queued == 0)

        #expect(await fixture.drainer.summary().queued == 1)
        #expect(await iterator.next()?.queued == 1)

        await fixture.drainer.drain()
        // A pass publishes when it starts and after each operation, so the count is a
        // sequence rather than a single value. What matters is where it lands.
        while let summary = await iterator.next(), summary.queued > 0 {
            continue
        }
        #expect(try await fixture.rows().isEmpty)
    }
}
