// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import NCMailStore

/// ``RowEffect`` through `enqueue` and `finish`: each family lands with its
/// `pendingOperation` row, or not at all (ADR-0005).
@Suite("Row effects")
struct RowEffectTests {
    private static func operation(accountId: Int64 = 1) -> PendingOperationRecord {
        PendingOperationRecord(
            kind: "rowEffect",
            accountId: accountId,
            messageId: nil,
            payloadJSON: "{}",
            createdAt: 1_700_000_000,
            baseSyncedAt: 100
        )
    }

    private static func seeded() async throws -> (MailStore, Int64) {
        let store = try MailStore.inMemory()
        try await Seed.base(store)
        try await store.upsert(envelopes: (1...3).map { Seed.envelope(remoteId: $0, sentAt: 100 + $0) })
        let login = try await store.ensureLogin(Seed.identity)
        return (store, try #require(login.id))
    }

    /// Enqueues one operation carrying `rows` and checks the row landed.
    private static func enqueue(_ store: MailStore, _ rows: [RowEffect]) async throws {
        let before = try await store.pendingOperations(accountId: 1).count
        let ids = try await store.enqueue([operation()], applying: [LocalEffect(messageIds: [], rows: rows)])
        #expect(ids.count == 1)
        #expect(try await store.pendingOperations(accountId: 1).count == before + 1)
    }

    /// Enqueues `rows` alongside a row the foreign key refuses; nothing may land.
    private static func expectRollback(_ store: MailStore, _ rows: [RowEffect]) async throws {
        let before = try await store.pendingOperations(accountId: 1).count
        await #expect(throws: (any Error).self) {
            try await store.enqueue(
                [operation(), operation(accountId: 9_999)],
                applying: [LocalEffect(messageIds: [], rows: rows), LocalEffect(messageIds: [])]
            )
        }
        #expect(try await store.pendingOperations(accountId: 1).count == before)
    }

    // MARK: Tags

    @Test("tags: upsert, link, placeholder replace keeps links, delete cascades")
    func tags() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.enqueue(
            store,
            [
                .upsertTag(accountId: 1, remoteId: -1, imapLabel: "$work", displayName: "Work", color: "#f00"),
                .setMessageTag(messageIds: [1, 2], accountId: 1, imapLabel: "$work", present: true),
            ])
        #expect(try await store.messageTagLabels(messageIds: [1, 2, 3]) == [1: ["$work"], 2: ["$work"]])

        try await Self.enqueue(
            store,
            [
                .replaceTagRemoteId(accountId: 1, from: -1, to: 42, imapLabel: "$label1")
            ])
        let tags = try await store.tags(accountId: 1)
        #expect(tags.map(\.remoteId) == [42])
        #expect(tags.map(\.imapLabel) == ["$label1"])
        #expect(try await store.messageTagLabels(messageIds: [1, 2]) == [1: ["$label1"], 2: ["$label1"]])

        try await Self.enqueue(
            store,
            [
                .setMessageTag(messageIds: [2], accountId: 1, imapLabel: "$label1", present: false)
            ])
        #expect(try await store.messageTagLabels(messageIds: [1, 2]) == [1: ["$label1"]])

        try await Self.enqueue(store, [.deleteTag(accountId: 1, remoteId: 42)])
        #expect(try await store.tags(accountId: 1).isEmpty)
        #expect(try await store.messageTagLabels(messageIds: [1]).isEmpty)
    }

    @Test("replacing a placeholder whose server row sync already mirrored merges the two")
    func tagReplaceMerges() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.enqueue(
            store,
            [
                .upsertTag(accountId: 1, remoteId: -1, imapLabel: "$work", displayName: "Work", color: nil),
                .setMessageTag(messageIds: [1], accountId: 1, imapLabel: "$work", present: true),
                .upsertTag(accountId: 1, remoteId: 42, imapLabel: "$label1", displayName: "Work", color: nil),
                .setMessageTag(messageIds: [2], accountId: 1, imapLabel: "$label1", present: true),
            ])
        try await Self.enqueue(store, [.replaceTagRemoteId(accountId: 1, from: -1, to: 42, imapLabel: "$label1")])
        let tags = try await store.tags(accountId: 1)
        #expect(tags.map(\.remoteId) == [42])
        #expect(try await store.messageTagLabels(messageIds: [1, 2]) == [1: ["$label1"], 2: ["$label1"]])
    }

    @Test("setMessageTag on a label with no tag is a no-op, and the row still lands")
    func setMessageTagAbsentLabel() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.enqueue(
            store,
            [
                .setMessageTag(messageIds: [1], accountId: 1, imapLabel: "$nope", present: true)
            ])
        #expect(try await store.messageTagLabels(messageIds: [1]).isEmpty)
    }

    @Test("a refused operation row rolls the row effect back")
    func rollback() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.expectRollback(
            store,
            [
                .upsertTag(accountId: 1, remoteId: -1, imapLabel: "$x", displayName: "X", color: nil)
            ])
        #expect(try await store.tags(accountId: 1).isEmpty)
    }

    // MARK: Mailboxes

    @Test("mailboxes: placeholder upsert, replace keeps messages, delete cascades messages")
    func mailboxes() async throws {
        let (store, _) = try await Self.seeded()
        var write = Seed.mailbox(id: 11, name: "Projects")
        write.remoteId = -1
        try await Self.enqueue(store, [.upsertMailbox(write)])
        let created = try #require(try await store.mailboxes(accountId: 1).first { $0.remoteId == -1 })
        #expect(created.isMirrored)

        try await store.upsert(envelopes: [Seed.envelope(remoteId: 50, mailboxId: created.id, sentAt: 1)])
        try await Self.enqueue(store, [.replaceMailboxRemoteId(accountId: 1, from: -1, to: 77)])
        let replaced = try #require(try await store.mailbox(id: created.id))
        #expect(replaced.remoteId == 77)
        #expect(try await store.messageIds(mailboxId: created.id).count == 1)

        #expect(try await store.messageIds(mailboxId: 10) == [1, 2, 3])
        #expect(try await store.unreadMessageIds(mailboxId: 10) == [1, 2, 3])
        try await store.enqueue([Self.operation()], applying: [LocalEffect(messageIds: [2], flags: ["seen": true])])
        #expect(try await store.unreadMessageIds(mailboxId: 10) == [1, 3])

        try await Self.enqueue(store, [.deleteMailbox(accountId: 1, remoteId: Seed.mailboxRemoteId(for: 10))])
        #expect(try await store.mailbox(id: 10) == nil)
        #expect(try await store.message(id: 1) == nil)
        #expect(try await store.messageIds(mailboxId: 10).isEmpty)
    }

    @Test("replacing a mailbox placeholder rewrites that account's special-mailbox columns only")
    func replaceMailboxRemoteIdRewritesAccountColumns() async throws {
        let (store, _) = try await Self.seeded()
        var mine = Seed.account()
        var other = Seed.account(remoteId: 2)
        for keyPath in [
            \AccountWrite.draftsMailboxId, \.sentMailboxId, \.trashMailboxId,
            \.archiveMailboxId, \.snoozeMailboxId, \.junkMailboxId,
        ] {
            mine[keyPath: keyPath] = -1
            other[keyPath: keyPath] = -1
        }
        mine.junkMailboxId = 5
        let accounts = try await store.upsert(accounts: [mine, other])
        #expect(accounts.first?.id == 1)
        let otherId = try #require(accounts.last?.id)

        try await Self.enqueue(store, [.replaceMailboxRemoteId(accountId: 1, from: -1, to: 77)])

        let replaced = try #require(try await store.account(id: 1))
        #expect(replaced.draftsMailboxId == 77)
        #expect(replaced.sentMailboxId == 77)
        #expect(replaced.trashMailboxId == 77)
        #expect(replaced.archiveMailboxId == 77)
        #expect(replaced.snoozeMailboxId == 77)
        #expect(replaced.junkMailboxId == 5)
        let untouched = try #require(try await store.account(id: otherId))
        #expect(untouched.snoozeMailboxId == -1)
        #expect(untouched.draftsMailboxId == -1)
    }

    // MARK: Snooze and account

    @Test("snooze sets and clears; account upserts")
    func snoozeAndAccount() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.enqueue(store, [.setSnooze(messageIds: [1, 2], until: 500)])
        let snoozed = try await store.read { db in
            try Int64.fetchAll(db, sql: "SELECT messageId FROM snooze WHERE until = 500 ORDER BY messageId")
        }
        #expect(snoozed == [1, 2])
        try await Self.enqueue(store, [.setSnooze(messageIds: [1], until: nil)])
        let left = try await store.read { db in try Int64.fetchAll(db, sql: "SELECT messageId FROM snooze") }
        #expect(left == [2])

        var account = Seed.account()
        account.name = "Renamed"
        try await Self.enqueue(store, [.upsertAccount(account)])
        #expect(try await store.account(id: 1)?.name == "Renamed")
    }

    // MARK: Settings

    @Test("aliases: placeholder create, replace, upsert keeps local id, delete")
    func aliases() async throws {
        let (store, _) = try await Self.seeded()
        try await Self.enqueue(store, [.upsertAlias(AliasRecord(accountId: 1, remoteId: -1, email: "a@x.invalid"))])
        let created = try #require(try await store.alias(accountId: 1, remoteId: -1))
        try await Self.enqueue(
            store,
            [
                .replaceAliasRemoteId(accountId: 1, from: -1, to: 9),
                .upsertAlias(AliasRecord(accountId: 1, remoteId: 9, email: "b@x.invalid")),
            ])
        let updated = try #require(try await store.alias(accountId: 1, remoteId: 9))
        #expect(updated.id == created.id)
        #expect(updated.email == "b@x.invalid")
        try await Self.enqueue(store, [.deleteAlias(accountId: 1, remoteId: 9)])
        #expect(try await store.alias(accountId: 1, remoteId: 9) == nil)
    }

    @Test("text blocks: placeholder create with shares, replace and upsert keep id and shares")
    func textBlocks() async throws {
        let (store, loginId) = try await Self.seeded()
        try await Self.enqueue(
            store,
            [
                .upsertTextBlock(TextBlockRecord(loginId: loginId, remoteId: -1, title: "Hi", content: "Hello")),
                .setTextBlockShare(
                    loginId: loginId, textBlockRemoteId: -1, shareWith: "bob", type: "user", displayName: "Bob",
                    present: true
                ),
            ])
        let created = try #require(try await store.textBlock(loginId: loginId, remoteId: -1))
        try await Self.enqueue(
            store,
            [
                .replaceTextBlockRemoteId(loginId: loginId, from: -1, to: 5),
                .upsertTextBlock(TextBlockRecord(loginId: loginId, remoteId: 5, title: "Hey", content: "Hello")),
            ])
        let updated = try #require(try await store.textBlock(loginId: loginId, remoteId: 5))
        #expect(updated.id == created.id)
        #expect(updated.title == "Hey")
        let blockId = try #require(updated.id)
        #expect(try await store.textBlockShares(textBlockId: blockId).map(\.shareWith) == ["bob"])

        try await Self.enqueue(
            store,
            [
                .setTextBlockShare(
                    loginId: loginId, textBlockRemoteId: 5, shareWith: "bob", type: "user", displayName: nil,
                    present: false
                )
            ])
        #expect(try await store.textBlockShares(textBlockId: blockId).isEmpty)
        try await Self.enqueue(store, [.deleteTextBlock(loginId: loginId, remoteId: 5)])
        #expect(try await store.textBlock(loginId: loginId, remoteId: 5) == nil)
    }

    @Test("quick actions: placeholder action and step, replace both, upsert keeps id and steps")
    func quickActions() async throws {
        let (store, _) = try await Self.seeded()
        let step = QuickActionStepRecord(quickActionId: 0, remoteId: -2, name: "markAsRead", position: 1)
        try await Self.enqueue(
            store,
            [
                .upsertQuickAction(QuickActionRecord(accountId: 1, remoteId: -1, name: "Triage")),
                .upsertQuickActionStep(accountId: 1, quickActionRemoteId: -1, step: step),
            ])
        let created = try #require(try await store.quickAction(accountId: 1, remoteId: -1))
        try await Self.enqueue(
            store,
            [
                .replaceQuickActionRemoteId(accountId: 1, from: -1, to: 3),
                .replaceQuickActionStepRemoteId(accountId: 1, quickActionRemoteId: 3, from: -2, to: 4),
                .upsertQuickAction(QuickActionRecord(accountId: 1, remoteId: 3, name: "Sort")),
            ])
        let updated = try #require(try await store.quickAction(accountId: 1, remoteId: 3))
        #expect(updated.id == created.id)
        #expect(updated.name == "Sort")
        let actionId = try #require(updated.id)
        #expect(try await store.quickActionSteps(quickActionId: actionId).map(\.remoteId) == [4])

        try await Self.enqueue(store, [.deleteQuickActionStep(accountId: 1, quickActionRemoteId: 3, stepRemoteId: 4)])
        #expect(try await store.quickActionSteps(quickActionId: actionId).isEmpty)
        try await Self.enqueue(store, [.deleteQuickAction(accountId: 1, remoteId: 3)])
        #expect(try await store.quickAction(accountId: 1, remoteId: 3) == nil)
    }

    @Test("quick action steps observation: keyed by action, sorted, fires on effects and replace")
    func observeQuickActionSteps() async throws {
        let (store, _) = try await Self.seeded()
        try await store.upsert(accounts: [Seed.account(remoteId: 2)])
        let otherAccountId = try #require(
            try await store.write { db in try Int64.fetchOne(db, sql: "SELECT id FROM account WHERE remoteId = 2") })
        let actions = try await store.replaceQuickActions(
            [
                QuickActionRecord(accountId: 1, remoteId: 3, name: "Triage"),
                QuickActionRecord(accountId: 1, remoteId: 5, name: "Sort"),
            ], accountId: 1)
        let other = try await store.replaceQuickActions(
            [QuickActionRecord(accountId: otherAccountId, remoteId: 3, name: "Other")], accountId: otherAccountId)
        let triage = try #require(actions[0].id)
        let sort = try #require(actions[1].id)
        let otherId = try #require(other[0].id)
        try await store.replaceQuickActionSteps(
            [QuickActionStepRecord(quickActionId: 0, remoteId: 9, name: "x", position: 1)], quickActionId: otherId)

        var iterator = store.observeQuickActionSteps(accountId: 1).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        try await store.replaceQuickActionSteps(
            [
                QuickActionStepRecord(quickActionId: 0, remoteId: 2, name: "b", position: 2),
                QuickActionStepRecord(quickActionId: 0, remoteId: 1, name: "a", position: 1),
            ], quickActionId: triage)
        var map = try #require(try await iterator.next())
        #expect(map.keys.sorted() == [triage])
        #expect(map[triage]?.map(\.remoteId) == [1, 2])

        let step = QuickActionStepRecord(quickActionId: 0, remoteId: 7, name: "c", position: 0)
        try await Self.enqueue(store, [.upsertQuickActionStep(accountId: 1, quickActionRemoteId: 5, step: step)])
        map = try #require(try await iterator.next())
        #expect(map[sort]?.map(\.remoteId) == [7])
        #expect(map[triage]?.map(\.remoteId) == [1, 2])

        try await Self.enqueue(store, [.deleteQuickActionStep(accountId: 1, quickActionRemoteId: 3, stepRemoteId: 1)])
        map = try #require(try await iterator.next())
        #expect(map[triage]?.map(\.remoteId) == [2])
        #expect(map[otherId] == nil)

        #expect(try await store.quickActionSteps(accountId: 1) == map)
        #expect(try await store.quickActionSteps(accountId: otherAccountId)[otherId]?.map(\.remoteId) == [9])
    }

    @Test("preferences, internal addresses, trusted senders, meta")
    func loginSettings() async throws {
        let (store, loginId) = try await Self.seeded()
        try await Self.enqueue(
            store,
            [
                .setPreference(loginId: loginId, key: "layout", value: "wide", fetchedAt: 1),
                .setInternalAddress(loginId: loginId, address: "example.org", type: "domain", present: true),
                .setTrustedSender(loginId: loginId, email: "a@b.invalid", type: "individual", present: true),
                .setMeta(key: "k", value: "v"),
            ])
        #expect(try await store.preferenceValue(key: "layout", loginId: loginId) == "wide")
        #expect(try await store.isAddressInternal(email: "x@example.org", loginId: loginId))
        #expect(try await store.isSenderTrusted(email: "a@b.invalid", loginId: loginId))
        #expect(try await store.metaValue(forKey: "k") == "v")

        try await Self.enqueue(
            store,
            [
                .setInternalAddress(loginId: loginId, address: "example.org", type: "domain", present: false),
                .setTrustedSender(loginId: loginId, email: "a@b.invalid", type: "individual", present: false),
                .setMeta(key: "k", value: nil),
            ])
        #expect(try await !store.isAddressInternal(email: "x@example.org", loginId: loginId))
        #expect(try await !store.isSenderTrusted(email: "a@b.invalid", loginId: loginId))
        #expect(try await store.metaValue(forKey: "k") == nil)
    }

    @Test("finish applies row effects with the delete")
    func finishAppliesRows() async throws {
        let (store, _) = try await Self.seeded()
        let ids = try await store.enqueue([Self.operation()], applying: [])
        try await store.finish(
            ids: ids, applying: [LocalEffect(messageIds: [], rows: [.setMeta(key: "f", value: "1")])])
        #expect(try await store.metaValue(forKey: "f") == "1")
        #expect(try await store.pendingOperations(accountId: 1).isEmpty)
    }
}
