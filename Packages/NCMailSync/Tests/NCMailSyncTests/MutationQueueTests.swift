// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The half of the queue that runs with the network switched off, which is all of
/// ``MutationQueue``: it applies the change, it writes the row, and it never sends anything.
///
/// Every test here runs against the real `MailStore`, so "one transaction" is SQLite's
/// answer rather than a fake's.
@Suite("Mutation queue")
struct MutationQueueTests {
    @Test func anActionTakenOfflineUpdatesTheMirrorAndQueuesOneRow() async throws {
        let fixture = try await QueueTest.make()
        let messageId = fixture.messageIds[0]

        try await fixture.queue.perform(
            .setFlags(messageIds: [messageId], flags: ["flagged": true]),
            accountId: fixture.accountId
        )

        #expect(try await fixture.message(0).isFlagged)
        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == "setFlags")
        #expect(rows.first?.messageId == messageId)
        #expect(rows.first?.state == .pending)
        // The whole point: nothing was sent, and nothing needed to be.
        #expect(await fixture.transport.sendCount == 0)
    }

    @Test func theRowCarriesAbsoluteIntentRatherThanAToggle() async throws {
        let fixture = try await QueueTest.make()
        try await fixture.queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )
        let row = try #require(try await fixture.rows().first)
        let payload = OperationPayload.decode(row.payloadJSON)
        #expect(payload.flags == ["seen": true])
    }

    @Test func aQueuedActionSurvivesAQuitAndARelaunch() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory)

        let messageId: Int64
        let accountId: Int64
        do {
            let fixture = try await QueueTest.make(url: url)
            messageId = fixture.messageIds[0]
            accountId = fixture.accountId
            try await fixture.queue.perform(
                .move(messageIds: [messageId], destinationMailboxId: fixture.archiveId),
                accountId: accountId
            )
        }
        // Everything above is out of scope now, which is as close to a relaunch as a test
        // gets: a second `MailStore` over the same file, nothing carried across in memory.
        let reopened = try MailStore(url: url)
        #expect(try await reopened.pendingOperations(accountId: accountId).count == 1)
        let message = try #require(try await reopened.message(id: messageId))
        #expect(message.mailboxId != 0)
        #expect(try await reopened.pendingOperations(accountId: accountId).first?.kind == "move")
    }

    @Test func tenArchivesThreeStarsAndTwoDeletesAllStick() async throws {
        let fixture = try await QueueTest.make(messages: 15)
        let archive = Array(fixture.messageIds.prefix(10))
        let stars = Array(fixture.messageIds[10..<13])
        let deletes = Array(fixture.messageIds[13..<15])

        try await fixture.queue.perform(
            .move(messageIds: archive, destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(
            .setFlags(messageIds: stars, flags: ["flagged": true]),
            accountId: fixture.accountId
        )
        try await fixture.queue.perform(.delete(messageIds: deletes), accountId: fixture.accountId)

        #expect(try await fixture.rows().count == 15)
        for id in archive {
            #expect(try await fixture.store.message(id: id)?.mailboxId == fixture.archiveId)
        }
        for id in stars {
            #expect(try await fixture.store.message(id: id)?.isFlagged == true)
        }
        for id in deletes {
            #expect(try await fixture.store.message(id: id)?.mailboxId == fixture.trashId)
        }
        #expect(await fixture.transport.sendCount == 0)
    }

    @Test func aSpecialMailboxResolvesToTheMirrorsIdAndNotTheServers() async throws {
        let fixture = try await QueueTest.make()
        let archive = try await fixture.queue.localMailboxId(for: .archive, accountId: fixture.accountId)

        #expect(archive == fixture.archiveId)
        // The reason this method exists. `account.archiveMailboxId` is the server's number,
        // and writing it into `message.mailboxId` would file the message under whichever
        // local mailbox happened to share it.
        #expect(archive != QueueTest.remoteArchive)
        #expect(try await fixture.queue.localMailboxId(for: .trash, accountId: fixture.accountId) == fixture.trashId)
        #expect(try await fixture.queue.localMailboxId(for: .junk, accountId: fixture.accountId) == fixture.junkId)
    }

    @Test func anActionOnAMessageTheMirrorHasLostQueuesNothing() async throws {
        let fixture = try await QueueTest.make()
        await #expect(throws: OperationError.self) {
            try await fixture.queue.perform(
                .setFlags(messageIds: [999_999], flags: ["seen": true]),
                accountId: fixture.accountId
            )
        }
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func junkIsTwoOperationsFlagsThenMove() async throws {
        let fixture = try await QueueTest.make()
        try await fixture.queue.perform(
            .junk(messageIds: [fixture.messageIds[0]], junkMailboxId: fixture.junkId),
            accountId: fixture.accountId
        )

        let rows = try await fixture.rows()
        #expect(rows.map(\.kind) == ["setFlags", "move"])
        #expect(try await fixture.message(0).isJunk)
        #expect(try await fixture.message(0).isNotJunk == false)
        #expect(try await fixture.message(0).mailboxId == fixture.junkId)
    }

    @Test func deletingMovesToTrashAndDeletingInTrashErasesTheRow() async throws {
        let fixture = try await QueueTest.make()
        let first = fixture.messageIds[0]

        try await fixture.queue.perform(.delete(messageIds: [first]), accountId: fixture.accountId)
        #expect(try await fixture.store.message(id: first)?.mailboxId == fixture.trashId)

        try await fixture.queue.perform(.delete(messageIds: [first]), accountId: fixture.accountId)
        #expect(try await fixture.store.message(id: first) == nil)
        let rows = try await fixture.rows()
        #expect(rows.count == 2)
        #expect(OperationPayload.decode(try #require(rows.last).payloadJSON).erases)
    }

    @Test func aThreadOperationTouchesEveryMessageOfTheThread() async throws {
        let fixture = try await QueueTest.make(messages: 12, threadSize: 3)
        let anchor = try await fixture.message(4)
        let rootId = try #require(anchor.threadRootId)
        let members = try await fixture.store.threadMessages(accountId: fixture.accountId, rootId: rootId)
        #expect(members.count > 1)

        try await fixture.queue.perform(
            .moveThread(rootId: rootId, destinationMailboxId: fixture.archiveId),
            accountId: fixture.accountId
        )

        for member in members {
            #expect(try await fixture.store.message(id: member.id)?.mailboxId == fixture.archiveId)
        }
        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.threadRootId == rootId)
        // One row, one request: `POST /api/thread/{id}` takes any member and resolves the
        // root itself.
        #expect(rows.first?.messageId == members.first?.id)
    }
}
