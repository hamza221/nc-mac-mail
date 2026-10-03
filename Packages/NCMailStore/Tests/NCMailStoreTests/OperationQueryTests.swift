// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// The queue DAO, from the store's side.
///
/// `NCMailSync` has the behavioural tests — what the drainer sends, what a 404 does, how a
/// discard reverts. These are about the five statements themselves: that one transaction is
/// one transaction, that the effect and the row land together, and that an id the mirror has
/// no column for cannot reach the UPDATE.
@Suite("Operation queue queries")
struct OperationQueryTests {
    private static func operation(
        kind: String = "setFlags",
        messageId: Int64,
        payload: String = #"{"flags":{"seen":true}}"#
    ) -> PendingOperationRecord {
        PendingOperationRecord(
            kind: kind,
            accountId: 1,
            messageId: messageId,
            payloadJSON: payload,
            createdAt: 1_700_000_000,
            baseSyncedAt: 100
        )
    }

    private static func seeded() async throws -> MailStore {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: (1...3).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) }
        )
        return store
    }

    @Test("the local change and the row it promises to send commit together")
    func enqueueAppliesTheEffectAndInsertsTheRow() async throws {
        let store = try await Self.seeded()

        let ids = try await store.enqueue(
            [Self.operation(messageId: 1)],
            applying: [LocalEffect(messageIds: [1], flags: ["seen": true])]
        )

        #expect(ids.count == 1)
        #expect(try await store.message(id: 1)?.isSeen == true)
        #expect(try await store.pendingOperations(accountId: 1).map(\.id) == ids)
    }

    /// A failing insert has to take the local change with it. Without that there is an
    /// instant in which the list says archived and nothing remembers to tell the server,
    /// which is the whole of ADR-0005.
    @Test("a row that cannot be inserted rolls the local change back with it")
    func enqueueIsAllOrNothing() async throws {
        let store = try await Self.seeded()

        await #expect(throws: (any Error).self) {
            try await store.enqueue(
                [
                    Self.operation(messageId: 1),
                    // No such account, so the foreign key refuses this row.
                    PendingOperationRecord(
                        kind: "setFlags",
                        accountId: 9_999,
                        messageId: 2,
                        payloadJSON: "{}",
                        createdAt: 1,
                        baseSyncedAt: 1
                    ),
                ],
                applying: [
                    LocalEffect(messageIds: [1], flags: ["flagged": true]),
                    LocalEffect(messageIds: [2], flags: ["flagged": true]),
                ]
            )
        }

        #expect(try await store.message(id: 1)?.isFlagged == false)
        #expect(try await store.message(id: 2)?.isFlagged == false)
        #expect(try await store.pendingOperations(accountId: 1).isEmpty)
    }

    @Test("a move writes the mailbox column, and an erase deletes the row")
    func effectsCoverMovesAndErasures() async throws {
        let store = try await Self.seeded()
        try await store.write { db in
            try MailboxRecord(
                id: 11,
                accountId: 1,
                remoteId: Seed.mailboxRemoteId(for: 11),
                name: "Archive",
                displayName: "Archive",
                isSubscribed: true,
                isMirrored: true
            ).insert(db)
        }

        try await store.enqueue(
            [Self.operation(kind: "move", messageId: 1), Self.operation(kind: "delete", messageId: 2)],
            applying: [
                LocalEffect(messageIds: [1], mailboxId: 11),
                LocalEffect(messageIds: [2], removesRows: true),
            ]
        )

        #expect(try await store.message(id: 1)?.mailboxId == 11)
        #expect(try await store.message(id: 2) == nil)
    }

    /// The setter accepts any IMAP keyword. Column names are looked up rather than
    /// interpolated, so one the mirror does not model is carried to the server and changes
    /// nothing locally — rather than reaching the UPDATE as a column name.
    @Test("a flag key with no column changes nothing and breaks nothing")
    func anUnmodelledFlagIsIgnoredLocally() async throws {
        let store = try await Self.seeded()

        try await store.enqueue(
            [Self.operation(messageId: 1)],
            applying: [LocalEffect(messageIds: [1], flags: ["$phishing": true, "seen": true])]
        )

        #expect(try await store.message(id: 1)?.isSeen == true)
        #expect(try await store.pendingOperations(accountId: 1).count == 1)
    }

    @Test("rows come back in id order, and only for the account asked about")
    func pendingOperationsAreScopedAndOrdered() async throws {
        let store = try await Self.seeded()
        try await store.upsert(accounts: [Seed.account(remoteId: 2)])
        let other = try #require(try await store.accounts().first { $0.remoteId == 2 })

        try await store.enqueue(
            [Self.operation(messageId: 1), Self.operation(kind: "move", messageId: 2)],
            applying: [LocalEffect(messageIds: []), LocalEffect(messageIds: [])]
        )
        try await store.enqueue(
            [
                PendingOperationRecord(
                    kind: "setFlags",
                    accountId: other.id,
                    messageId: 3,
                    payloadJSON: "{}",
                    createdAt: 2,
                    baseSyncedAt: 1
                )
            ],
            applying: []
        )

        let rows = try await store.pendingOperations(accountId: 1)
        #expect(rows.map(\.kind) == ["setFlags", "move"])
        let orderedIds = rows.compactMap(\.id)
        #expect(orderedIds == orderedIds.sorted())
        #expect(try await store.pendingOperations(accountId: other.id).count == 1)
    }

    @Test("claiming, rescheduling and finishing move the row through its three states")
    func theRowIsClaimedRescheduledAndCleared() async throws {
        let store = try await Self.seeded()
        let ids = try await store.enqueue(
            [Self.operation(messageId: 1)],
            applying: [LocalEffect(messageIds: [1], flags: ["seen": true])]
        )

        try await store.markInFlight(ids: ids)
        #expect(try await store.pendingOperations(accountId: 1).first?.state == .inFlight)

        try await store.reschedule(ids: ids, attempts: 3, nextAttemptAt: 1_700_000_030, lastError: "503")
        var row = try #require(try await store.pendingOperations(accountId: 1).first)
        #expect(row.state == .pending)
        #expect(row.attempts == 3)
        #expect(row.nextAttemptAt == 1_700_000_030)
        #expect(row.lastError == "503")

        // nil attempts is what a 429 passes: the server asked for patience, and patience is
        // not a failure.
        try await store.reschedule(ids: ids, attempts: nil, nextAttemptAt: nil, lastError: nil)
        row = try #require(try await store.pendingOperations(accountId: 1).first)
        #expect(row.attempts == 3)
        #expect(row.nextAttemptAt == nil)

        // Discard: drop the row and put the mirror back.
        try await store.finish(ids: ids, applying: [LocalEffect(messageIds: [1], flags: ["seen": false])])
        #expect(try await store.pendingOperations(accountId: 1).isEmpty)
        #expect(try await store.message(id: 1)?.isSeen == false)
    }

    @Test("a thread reads oldest first, across the account rather than one mailbox")
    func threadMessagesAreOldestFirst() async throws {
        let store = try await Self.seeded()
        try await store.write { db in
            try MailboxRecord(
                id: 11,
                accountId: 1,
                remoteId: Seed.mailboxRemoteId(for: 11),
                name: "Archive",
                displayName: "Archive",
                isSubscribed: true,
                isMirrored: true
            ).insert(db)
        }
        try await store.upsert(
            envelopes: [
                Seed.envelope(remoteId: 10, sentAt: 300, threadRootId: "<root>"),
                Seed.envelope(remoteId: 11, sentAt: 100, threadRootId: "<root>"),
                Seed.envelope(remoteId: 12, mailboxId: 11, sentAt: 200, threadRootId: "<root>"),
                Seed.envelope(remoteId: 13, sentAt: 400, threadRootId: "<other>"),
            ]
        )

        let members = try await store.threadMessages(accountId: 1, rootId: "<root>")
        #expect(members.map(\.remoteId) == [11, 12, 10])
        #expect(try await store.threadMessages(accountId: 1, rootId: "<nothing>").isEmpty)
    }

    @Test("an empty id list is a no-op rather than a malformed statement")
    func emptyListsDoNothing() async throws {
        let store = try await Self.seeded()
        try await store.markInFlight(ids: [])
        try await store.reschedule(ids: [], attempts: 1, nextAttemptAt: nil, lastError: nil)
        try await store.finish(ids: [], applying: [])
        #expect(try await store.enqueue([], applying: []).isEmpty)
        #expect(try await store.pendingOperations(accountId: 1).isEmpty)
    }
}
