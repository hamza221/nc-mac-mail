// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// The local half of the sidebar's Get info panel: what the mirror holds for one mailbox.
@Suite("Mailbox counts")
struct MailboxCountsTests {
    /// INBOX (10) with four messages -- two unread, one body present, one failed -- and a
    /// second mailbox (11) with one message, so a count that forgot its `WHERE` shows up.
    private static func seeded() async throws -> MailStore {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(mailboxes: [Seed.mailbox(id: 11, name: "Archive")], accountId: 1)
        try await store.upsert(envelopes: [
            Seed.envelope(remoteId: 1, sentAt: 100, isSeen: false),
            Seed.envelope(remoteId: 2, sentAt: 200, isSeen: false),
            Seed.envelope(remoteId: 3, sentAt: 300, isSeen: true),
            Seed.envelope(remoteId: 4, sentAt: 400, isSeen: true),
            Seed.envelope(remoteId: 5, mailboxId: 11, sentAt: 500, isSeen: false),
        ])
        try await store.write { db in
            try db.execute(sql: "UPDATE message SET bodyState = 'present' WHERE remoteId IN (1, 5)")
            try db.execute(sql: "UPDATE message SET bodyState = 'failed' WHERE remoteId = 2")
        }
        return store
    }

    @Test("counts only the mailbox asked about")
    func countsOneMailbox() async throws {
        let store = try await Self.seeded()
        #expect(
            try await store.mailboxCounts(mailboxId: 10)
                == MailboxCounts(messageCount: 4, unreadCount: 2, bodiesPresent: 1, bodiesFailed: 1)
        )
    }

    @Test("an empty mailbox reads as zeros, not as missing")
    func emptyMailboxIsZero() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        #expect(try await store.mailboxCounts(mailboxId: 10) == .empty)
    }

    @Test("reading a message locally reaches an open panel without a server round trip")
    func localReadUpdatesObserver() async throws {
        let store = try await Self.seeded()

        var received: [Int] = []
        for try await counts in store.observeMailboxCounts(mailboxId: 10) {
            received.append(counts.unreadCount)
            if received.count == 1 {
                _ = try await Task.detached {
                    try await store.write { db in
                        try db.execute(sql: "UPDATE message SET isSeen = 1 WHERE remoteId = 1")
                    }
                }.value
            } else {
                break
            }
        }

        #expect(received == [2, 1])
    }
}
