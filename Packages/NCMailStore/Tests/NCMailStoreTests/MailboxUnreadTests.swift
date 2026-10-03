// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// The sidebar's unread figure (ADR-0060): the mirror's own count once a mailbox is complete,
/// the server's until then.
@Suite("Mailbox unread count")
struct MailboxUnreadTests {
    /// INBOX with the server claiming 50 unread, and three local messages of which two are
    /// unread.
    private static func seeded(envelopesComplete: Bool) async throws -> MailStore {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [
            Seed.envelope(remoteId: 1, sentAt: 100, isSeen: false),
            Seed.envelope(remoteId: 2, sentAt: 200, isSeen: false),
            Seed.envelope(remoteId: 3, sentAt: 300, isSeen: true),
        ])
        try await store.write { db in
            try db.execute(
                sql: "UPDATE mailbox SET unreadCount = 50, envelopesComplete = ? WHERE id = 10",
                arguments: [envelopesComplete]
            )
        }
        return store
    }

    @Test("a complete mailbox counts its own unread messages, not the server's stale figure")
    func completeMailboxCountsLocally() async throws {
        let store = try await Self.seeded(envelopesComplete: true)
        #expect(try await store.mailboxes(accountId: 1).first?.unreadCount == 2)
    }

    @Test("a mailbox still being enumerated keeps the server's figure")
    func incompleteMailboxKeepsServerCount() async throws {
        let store = try await Self.seeded(envelopesComplete: false)
        #expect(try await store.mailboxes(accountId: 1).first?.unreadCount == 50)
    }

    @Test("marking a message read locally reaches a sidebar observer without a server round trip")
    func localReadUpdatesObserver() async throws {
        let store = try await Self.seeded(envelopesComplete: true)

        var received: [Int] = []
        for try await mailboxes in store.observeMailboxes(accountId: 1) {
            received.append(mailboxes.first?.unreadCount ?? -1)
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
