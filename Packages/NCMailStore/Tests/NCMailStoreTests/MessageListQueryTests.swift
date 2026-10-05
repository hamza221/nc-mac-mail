// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Message list queries")
struct MessageListQueryTests {
    private static func envelope(
        remoteId: Int64,
        mailboxId: Int64 = 10,
        accountId: Int64 = 1,
        sentAt: Int64,
        threadRootId: String? = nil,
        isSeen: Bool = false,
        isFlagged: Bool = false,
        isImportant: Bool = false,
        tags: [TagWrite] = []
    ) -> EnvelopeWrite {
        var envelope = Seed.envelope(
            remoteId: remoteId,
            mailboxId: mailboxId,
            accountId: accountId,
            sentAt: sentAt,
            threadRootId: threadRootId,
            isSeen: isSeen
        )
        envelope.isFlagged = isFlagged
        envelope.isImportant = isImportant
        envelope.tags = tags
        return envelope
    }

    private static let followUp = TagWrite(remoteId: 1, imapLabel: "$follow_up", displayName: "Follow up")
    private static let work = TagWrite(remoteId: 2, imapLabel: "$label1", displayName: "Work")

    private static func mailbox(
        _ store: MailStore,
        id: Int64,
        accountId: Int64,
        role: String?,
        selectable: Bool = true
    ) async throws {
        try await store.write { db in
            try MailboxRecord(
                id: id,
                accountId: accountId,
                remoteId: Seed.mailboxRemoteId(for: id),
                name: "box\(id)",
                displayName: "box\(id)",
                specialRole: role,
                isSelectable: selectable
            ).insert(db)
        }
    }

    @Test func sortsNewestAndOldestFirst() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...5).map { Self.envelope(remoteId: $0, sentAt: 100 + $0) })
        let query = MessageListQuery(mailboxIds: [10])

        let newest = try await store.messages(query: query, view: .flat, order: .newest, range: 0..<3)
        #expect(newest.map(\.id) == [5, 4, 3])
        let oldest = try await store.messages(query: query, view: .flat, order: .oldest, range: 0..<3)
        #expect(oldest.map(\.id) == [1, 2, 3])
        let oldestNext = try await store.messages(query: query, view: .flat, order: .oldest, range: 3..<6)
        #expect(oldestNext.map(\.id) == [4, 5])
    }

    @Test func rowsCarryTheNewColumns() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        var draft = Self.envelope(remoteId: 1, sentAt: 100, isImportant: true)
        draft.isDraft = true
        draft.summary = "In short"
        try await store.upsert(envelopes: [draft])

        let row = try #require(
            try await store.messages(
                query: MessageListQuery(mailboxIds: [10]), view: .flat, order: .newest, range: 0..<1
            )
            .first)
        #expect(row.accountId == 1)
        #expect(row.isImportant)
        #expect(row.isDraft)
        #expect(row.summary == "In short")
    }

    @Test func severalMailboxesUnion() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await Self.mailbox(store, id: 11, accountId: 1, role: nil)
        try await store.upsert(
            envelopes: [
                Self.envelope(remoteId: 1, mailboxId: 10, sentAt: 100),
                Self.envelope(remoteId: 2, mailboxId: 11, sentAt: 200),
                Self.envelope(remoteId: 3, mailboxId: 10, sentAt: 300),
            ]
        )
        let rows = try await store.messages(
            query: MessageListQuery(mailboxIds: [10, 11]), view: .flat, order: .newest, range: 0..<10)
        #expect(rows.map(\.id) == [3, 2, 1])
        #expect(rows.map(\.mailboxId) == [10, 11, 10])
        // No mailbox ids: every mailbox.
        let all = try await store.messages(
            query: MessageListQuery(mailboxIds: []), view: .flat, order: .oldest, range: 0..<10)
        #expect(all.map(\.id) == [1, 2, 3])
    }

    @Test func predicatesSinglyAndCombined() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Self.envelope(remoteId: 1, sentAt: 100, isFlagged: true),
                Self.envelope(remoteId: 2, sentAt: 200, isImportant: true),
                Self.envelope(remoteId: 3, sentAt: 300, isFlagged: true, isImportant: true),
                Self.envelope(remoteId: 4, sentAt: 400, tags: [Self.followUp]),
                Self.envelope(remoteId: 5, sentAt: 500, tags: [Self.followUp, Self.work]),
                Self.envelope(remoteId: 6, sentAt: 600),
            ]
        )
        func ids(_ query: MessageListQuery) async throws -> [Int64] {
            try await store.messages(query: query, view: .flat, order: .newest, range: 0..<20).map(\.id)
        }

        #expect(try await ids(MessageListQuery(mailboxIds: [10], isFlagged: true)) == [3, 1])
        #expect(try await ids(MessageListQuery(mailboxIds: [10], isImportant: true)) == [3, 2])
        #expect(try await ids(MessageListQuery(mailboxIds: [10], isImportant: false)) == [6, 5, 4, 1])
        #expect(try await ids(MessageListQuery(mailboxIds: [10], tagImapLabel: "$follow_up")) == [5, 4])
        #expect(try await ids(MessageListQuery(mailboxIds: [10], sentAtOrBefore: 300)) == [3, 2, 1])
        #expect(try await ids(MessageListQuery(mailboxIds: [10], isFlagged: true, isImportant: true)) == [3])
        // Priority "Important" section excluding flagged ones.
        #expect(try await ids(MessageListQuery(mailboxIds: [10], isFlagged: false, isImportant: true)) == [2])
        // Follow up: tagged and old enough.
        #expect(
            try await ids(MessageListQuery(mailboxIds: [10], tagImapLabel: "$follow_up", sentAtOrBefore: 450)) == [4])
    }

    @Test func threadedRowsUnderAQuery() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await Self.mailbox(store, id: 11, accountId: 1, role: nil)
        try await store.upsert(
            envelopes: [
                Self.envelope(remoteId: 1, sentAt: 100, threadRootId: "t1", isSeen: true, isFlagged: true),
                Self.envelope(remoteId: 2, sentAt: 200, threadRootId: "t1", isFlagged: true),
                Self.envelope(remoteId: 3, sentAt: 300, threadRootId: "t1"),
                Self.envelope(remoteId: 4, sentAt: 250, threadRootId: "t2", isFlagged: true),
                Self.envelope(remoteId: 5, mailboxId: 11, sentAt: 400, threadRootId: "t2"),
                Self.envelope(remoteId: 6, sentAt: 50, isFlagged: true),
            ]
        )

        // The newest of t1 (id 3) is not flagged, so t1 is not drawn under "flagged".
        let flagged = try await store.messages(
            query: MessageListQuery(mailboxIds: [10], isFlagged: true), view: .threaded, order: .newest, range: 0..<10)
        #expect(flagged.map(\.id) == [4, 6])

        // Unified over both mailboxes: t2 shows once per mailbox, counted within it.
        let both = try await store.messages(
            query: MessageListQuery(mailboxIds: [10, 11]), view: .threaded, order: .newest, range: 0..<10)
        #expect(both.map(\.id) == [5, 3, 4, 6])
        #expect(both.map(\.threadCount) == [1, 3, 1, 1])
        #expect(both.map(\.threadUnreadCount) == [1, 2, 1, 1])

        let oldest = try await store.messages(
            query: MessageListQuery(mailboxIds: [10]), view: .threaded, order: .oldest, range: 0..<10)
        #expect(oldest.map(\.id) == [6, 4, 3])
    }

    @Test func inboxIdsReactToANewAccount() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert(accounts: [Seed.account()])
        try await Self.mailbox(store, id: 10, accountId: 1, role: "inbox")
        try await Self.mailbox(store, id: 11, accountId: 1, role: "sent")
        try await Self.mailbox(store, id: 12, accountId: 1, role: "inbox", selectable: false)

        var received: [[Int64]] = []
        for try await ids in store.observeInboxMailboxIds() {
            received.append(ids)
            if received.count == 1 {
                _ = try await Task.detached {
                    let accounts = try await store.upsert(accounts: [Seed.account(remoteId: 2)])
                    try await Self.mailbox(store, id: 20, accountId: accounts[0].id, role: "inbox")
                }.value
            } else if ids.count == 2 {
                break
            }
        }
        #expect(received.first == [10])
        #expect(received.last == [10, 20])
    }

    @Test func batchTagsMap() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(
            envelopes: [
                Self.envelope(remoteId: 1, sentAt: 100, tags: [Self.work, Self.followUp]),
                Self.envelope(remoteId: 2, sentAt: 200),
                Self.envelope(remoteId: 3, sentAt: 300, tags: [Self.work]),
            ]
        )
        var iterator = store.observeTags(messageIds: [1, 2, 3]).makeAsyncIterator()
        let map = try #require(try await iterator.next())
        #expect(map[1]?.map(\.imapLabel) == ["$follow_up", "$label1"])
        #expect(map[2] == nil)
        #expect(map[3]?.map(\.imapLabel) == ["$label1"])
        #expect(try await store.tags(messageIds: []).isEmpty)
    }

    @Test func batchAttachmentChips() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [
            Self.envelope(remoteId: 1, sentAt: 100), Self.envelope(remoteId: 2, sentAt: 200),
        ])
        try await store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO attachment (messageId, attachmentId, isInline, fileName, mime) VALUES
                    (1, 'b', 0, 'b.pdf', 'application/pdf'),
                    (1, 'a', 0, 'a.txt', NULL),
                    (1, 'c', 1, 'logo.png', 'image/png'),
                    (2, 'd', 0, '', NULL),
                    (2, 'e', 0, NULL, NULL)
                    """)
        }
        let map = try await store.attachmentChips(messageIds: [1, 2])
        #expect(map[1]?.map(\.fileName) == ["a.txt", "b.pdf"])
        #expect(map[1]?.last?.mime == "application/pdf")
        #expect(map[2] == nil)
    }

    @Test func batchServerResults() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        let loginId = try await store.write { db in
            try db.execute(
                sql: "INSERT INTO login (serverURL, loginName) VALUES ('https://two.example.invalid/', 'bo')")
            return db.lastInsertedRowID
        }
        try await store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO serverResult (loginId, kind, key, payloadJSON, fetchedAt) VALUES
                    (?, 'threadSummary', '2', '{}', 1),
                    (?, 'threadSummary', '1', '{}', 1),
                    (?, 'followUp', '1', '{}', 1),
                    (?, 'threadSummary', '9', '{}', 1)
                    """,
                arguments: [loginId, loginId, loginId, loginId])
        }
        var iterator = store.observeServerResults(kind: "threadSummary", keys: ["1", "2", "3"]).makeAsyncIterator()
        let rows = try #require(try await iterator.next())
        #expect(rows.map(\.key) == ["1", "2"])
    }
}
