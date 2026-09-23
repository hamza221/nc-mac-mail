// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The real queue inside the real scheduler.
///
/// `SyncSchedulerTests` proves the conflict rule against a `FakeDrainer`, which is the right
/// test for the scheduler. These two prove the other half: that ``OperationDrainer`` is the
/// `OperationDraining` the scheduler was written against, and that the intent a real queue
/// row produces is the one the sync masks with.
@Suite("Queue and sync together")
struct OperationSyncConflictTests {
    @Test("A sync while the drain cannot reach the server leaves the user's field alone")
    func aQueuedFlagSurvivesASyncThatContradictsIt() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let target = Recorded.id(rows[5])
        let localId = try #require(seeded.localByRemote[target])

        let transport = FakeTransport()
        let operations = MailStoreOperations(store: seeded.store)
        let drainer = OperationDrainer(
            store: operations,
            client: try MirrorTest.client(transport),
            accountId: seeded.accountId
        )
        let queue = MutationQueue(store: operations)
        try await queue.perform(.setFlags(messageIds: [localId], flags: ["seen": true]), accountId: seeded.accountId)

        // The train. Every attempt to tell the server fails, so the row stays queued.
        await transport.fail(QueueTest.flagsRoute, times: 10_000, then: .status(200))
        let serverView =
            rows.filter { Recorded.id($0) != target }
            + Recorded.settingFlag("seen", to: false, on: rows.filter { Recorded.id($0) == target })
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: 5),
            with: try Recorded.syncResponse(changed: serverView, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(rows))

        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            drainer: drainer
        )
        await scheduler.syncNow(mailboxId: seeded.inboxId)

        #expect(try await seeded.store.message(id: localId)?.isSeen == true)
        #expect(try await operations.pendingOperations(accountId: seeded.accountId).count == 1)
    }

    @Test("Once the drain has sent it, the server owns the field again")
    func aDrainedOperationLeavesNothingToMask() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let target = Recorded.id(rows[5])
        let localId = try #require(seeded.localByRemote[target])

        let transport = FakeTransport()
        let operations = MailStoreOperations(store: seeded.store)
        let drainer = OperationDrainer(
            store: operations,
            client: try MirrorTest.client(transport),
            accountId: seeded.accountId
        )
        let queue = MutationQueue(store: operations)
        try await queue.perform(.setFlags(messageIds: [localId], flags: ["seen": true]), accountId: seeded.accountId)

        await QueueTest.stubEverything(transport)
        // The server's answer disagrees, and by the time it is written the queue is empty —
        // so it wins, which is the "no pending operation: server, always" row of the table.
        let serverView =
            rows.filter { Recorded.id($0) != target }
            + Recorded.settingFlag("seen", to: false, on: rows.filter { Recorded.id($0) == target })
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: 5),
            with: try Recorded.syncResponse(changed: serverView, total: rows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(rows))

        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            drainer: drainer
        )
        await scheduler.syncNow(mailboxId: seeded.inboxId)

        #expect(try await operations.pendingOperations(accountId: seeded.accountId).isEmpty)
        #expect(try await seeded.store.message(id: localId)?.isSeen == false)
    }
}
