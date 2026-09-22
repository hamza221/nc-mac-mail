// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

@Suite("Observation")
struct ObservationTests {
    /// The shape every store in the app uses: start observing, let a write happen somewhere
    /// else entirely, and receive the new rows without asking for them.
    ///
    /// No sleep and no timeout. The loop waits on the sequence, which is what the real
    /// `MessageListStore` does.
    @Test func aBackgroundWriteReachesAnObserver() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])

        var received: [[Int64]] = []
        for try await rows in store.observeMessages(mailboxId: 10, view: .flat, range: 0..<50) {
            received.append(rows.map(\.id))
            if received.count == 1 {
                // Written from a detached task so the write genuinely is not the observer's.
                try await Task.detached {
                    try await store.upsert(envelopes: [Seed.envelope(id: 2, sentAt: 200)])
                }.value
            } else {
                break
            }
        }

        #expect(received == [[1], [2, 1]])
    }

    /// GRDB is told to schedule on the main actor, because the values land in `@Observable`
    /// stores that SwiftUI reads. If this ever changed, every list in the app would be
    /// mutating main-actor state from a background thread.
    @Test @MainActor func valuesAreDeliveredOnTheMainActor() async throws {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: [Seed.envelope(id: 1, sentAt: 100)])

        for try await _ in store.observeMessages(mailboxId: 10, view: .flat, range: 0..<50) {
            MainActor.assertIsolated("ValueObservation must deliver on the main actor")
            break
        }
        for try await _ in store.observeAccounts() {
            MainActor.assertIsolated("ValueObservation must deliver on the main actor")
            break
        }
    }

    @Test func mailboxesAreObservedAsRowsAndUpdateLive() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert(accounts: [Seed.account()])
        try await store.upsert(mailboxes: [Seed.mailbox(id: 10)], accountId: 1)

        var received: [[String]] = []
        for try await mailboxes in store.observeMailboxes(accountId: 1) {
            received.append(mailboxes.map(\.name))
            if received.count == 1 {
                try await Task.detached {
                    try await store.upsert(
                        mailboxes: [Seed.mailbox(id: 11, name: "Archive")],
                        accountId: 1
                    )
                }.value
            } else {
                break
            }
        }

        #expect(received == [["INBOX"], ["Archive", "INBOX"]])
    }

    /// `avatar` and `meta` were WITHOUT ROWID until this test was written, and neither of them
    /// ever delivered a second value. Keeping the assertion is how that stays fixed.
    @Test func anAvatarArrivingReachesAnObserver() async throws {
        let store = try MailStore.inMemory()

        var received: [Int] = []
        let observation =
            ValueObservation
            .tracking { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM avatar") ?? -1 }
            .values(in: store.dbQueue, scheduling: .mainActor)
        for try await count in observation {
            received.append(count)
            if received.count == 1 {
                try await Task.detached {
                    try await store.write { db in
                        try AvatarRecord(email: "ada@example.invalid", fetchedAt: 1).insert(db)
                    }
                }.value
            } else {
                break
            }
        }

        #expect(received == [0, 1])
    }

    @Test func aMetaValueCanBeObserved() async throws {
        let store = try MailStore.inMemory()

        var received: [String?] = []
        for try await value in store.observeMetaValue(forKey: "sidebar.expanded") {
            received.append(value)
            if received.count == 1 {
                try await Task.detached {
                    try await store.setMetaValue("10,11", forKey: "sidebar.expanded")
                }.value
            } else {
                break
            }
        }

        #expect(received == [nil, "10,11"])
    }
}
