// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-29: layouts, sort order, sections and preferences, against a real in-memory mirror.
@Suite("Message list v2")
@MainActor
struct MessageListV2Tests {
    private static let base: Int64 = 1_700_000_000

    // MARK: - Plans (pure)

    @Test("a mailbox is one date-grouped list, or Favorites then the unstarred rest")
    func mailboxPlans() {
        var preferences = MessageListPreferences()
        let plain = MessageListPlan.plans(for: .mailbox(7), inboxIds: [], preferences: preferences, now: 0)
        #expect(plain.map(\.bucket) == [.all])
        #expect(plain.first?.query == MessageListQuery(mailboxIds: [7]))
        #expect(plain.first?.isDateGrouped == true)

        preferences.favoritesOnTop = true
        let split = MessageListPlan.plans(for: .mailbox(7), inboxIds: [], preferences: preferences, now: 0)
        #expect(split.map(\.bucket) == [.favorites, .all])
        #expect(split.map(\.query.isFlagged) == [true, false])
        #expect(split.map(\.isDateGrouped) == [false, true])
    }

    @Test("Priority inbox: Favorites, Follow up, Important, Other, each switchable")
    func priorityPlans() {
        var preferences = MessageListPreferences()
        let now: Int64 = 2_000_000_000
        let plans = MessageListPlan.plans(for: .priorityInbox, inboxIds: [1, 2], preferences: preferences, now: now)
        #expect(plans.map(\.bucket) == [.followUp, .important, .other])
        #expect(plans.allSatisfy { !$0.isDateGrouped })
        let followUp = plans[0].query
        #expect(followUp.mailboxIds.isEmpty)
        #expect(followUp.tagImapLabel == "$follow_up")
        #expect(followUp.sentAtOrBefore == now - 4 * 86_400)
        #expect(plans[1].query == MessageListQuery(mailboxIds: [1, 2], isImportant: true))
        #expect(plans[2].query == MessageListQuery(mailboxIds: [1, 2], isImportant: false))

        preferences.favoritesOnTop = true
        preferences.followUpReminders = false
        let starred = MessageListPlan.plans(for: .priorityInbox, inboxIds: [1, 2], preferences: preferences, now: now)
        #expect(starred.map(\.bucket) == [.favorites, .important, .other])
        // Starred messages are shown once, in Favorites.
        #expect(starred.map(\.query.isFlagged) == [true, false, false])
    }

    @Test("with no Inbox known, a merged list queries nothing rather than every mailbox")
    func noInboxesNoPlans() {
        let preferences = MessageListPreferences()
        #expect(MessageListPlan.plans(for: .unifiedInbox, inboxIds: [], preferences: preferences, now: 0).isEmpty)
        #expect(MessageListPlan.plans(for: .priorityInbox, inboxIds: [], preferences: preferences, now: 0).isEmpty)
        let favorites = MessageListPlan.plans(
            for: .favorites(inboxId: 3), inboxIds: [], preferences: preferences, now: 0)
        #expect(favorites.map(\.query) == [MessageListQuery(mailboxIds: [3], isFlagged: true)])
    }

    @Test("preferences parse the web's spellings and fall back to its defaults")
    func preferenceParsing() {
        let defaults = MessageListPreferences(values: [:])
        #expect(defaults == MessageListPreferences())
        #expect(defaults.layout == .verticalSplit && defaults.sortOrder == .newest && defaults.followUpReminders)

        let set = MessageListPreferences(values: [
            "layout-mode": "no-split", "compact-mode": "true", "sort-order": "oldest", "sort-favorites": "true",
            "follow-up-reminders": "false",
        ])
        #expect(set.layout == .list)
        #expect(set.isCompact && set.favoritesOnTop && !set.followUpReminders)
        #expect(set.sortOrder == .oldest)
        #expect(MessageListPreferences(values: ["layout-mode": "something-new"]).layout == .verticalSplit)
        #expect(MessageListLayout.horizontalSplit.rawValue == "horizontal-split")
    }

    // MARK: - Layout switching keeps the selection

    @Test("switching layout keeps the selection and the opened message, and the rows stay live")
    func layoutSwitchKeepsSelection() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: (1...5).map { Self.base + $0 })
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)

        // The vertical layout's list view appears and shows the mailbox.
        model.attach()
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 5 })
        let picked = Set(model.rows.prefix(2).map(\.id))
        model.selection = picked
        model.openedMessageId = model.rows.first?.id

        // Layout change, new view first: the horizontal layout's list appears before the
        // vertical one goes. Nothing stops in between.
        model.attach()
        model.detach()
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(model.selection == picked)

        // Layout change, old view first: the list layout's view appears only after the last
        // one has gone, so the observations stop and must resume.
        model.detach()
        #expect(model.selection == picked)
        model.attach()
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(model.selection == picked)
        #expect(model.openedMessageId != nil)

        try await mirror.addMessages(sentAt: [Self.base + 99], firstRemoteId: 99)
        #expect(await waitUntil { model.rows.count == 6 })
        #expect(model.selection == picked)
    }

    // MARK: - Sort order and preferences

    @Test("oldest first reverses the rows and the date groups, and keeps the selection")
    func sortOrderReorders() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: (1...4).map { Self.base + $0 })
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 4 })
        #expect(model.rows.map(\.sentAt) == (1...4).reversed().map { Self.base + $0 })
        model.selection = [try #require(model.rows.first).id]

        var oldest = MessageListPreferences.Querying()
        oldest.sortOrder = .oldest
        model.show(.mailbox(mirror.mailboxId), view: .flat, preferences: oldest)
        #expect(await waitUntil { model.rows.first?.sentAt == Self.base + 1 })
        #expect(model.rows.map(\.sentAt) == (1...4).map { Self.base + $0 })
        #expect(model.selection.count == 1)
    }

    @Test("changing the sort order queues a setPreference for the server")
    func sortOrderGoesThroughTheQueue() async throws {
        let mirror = try await MessageListMirror.seed()
        let account = try #require(try await mirror.store.account(id: mirror.accountId))
        let login = try await mirror.store.ensureLogin(account.identity)
        let loginId = try #require(login.id)
        let store = mirror.store
        let preferences = MessageListPreferenceStore(store: store, queue: { _ in MutationQueue(store: store) })
        preferences.start()

        await preferences.set(sortOrder: .oldest)

        let queued = try await store.pendingOperations(accountId: mirror.accountId)
        #expect(queued.map(\.kind) == ["setPreference"])
        #expect(queued.first?.payloadJSON.contains("sort-order") == true)
        #expect(queued.first?.payloadJSON.contains("oldest") == true)
        // Applied locally in the same transaction, which is what the list reads back.
        #expect(try await store.preferenceValue(key: "sort-order", loginId: loginId) == "oldest")
        #expect(await waitUntil { preferences.preferences.sortOrder == .oldest })

        // The value the server already has is not queued again.
        await preferences.set(sortOrder: .oldest)
        #expect(try await store.pendingOperations(accountId: mirror.accountId).count == 1)

        await preferences.set(layout: .horizontalSplit)
        #expect(await waitUntil { preferences.preferences.layout == .horizontalSplit })
        preferences.stop()
    }

    // MARK: - Sections

    @Test("favorites on top: a Favorites section, then the rest in date groups")
    func favoritesSection() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: [Self.base + 1, Self.base + 2], firstRemoteId: 1, isFlagged: true)
        try await mirror.addMessages(sentAt: [Self.base + 3], firstRemoteId: 3)
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)
        var favorites = MessageListPreferences.Querying()
        favorites.favoritesOnTop = true

        model.show(.mailbox(mirror.mailboxId), view: .flat, preferences: favorites)
        #expect(await waitUntil { model.rows.count == 3 })
        #expect(model.sections.map(\.bucket) == [.favorites, .all])
        #expect(model.sections.first?.title == "Favorites")
        #expect(model.sections.first?.rows.allSatisfy { $0.isFlagged } == true)
        #expect(model.sections.last?.dateGroup == .year(2023))
        // Triage and ⌘A see the on-screen order: favorites first.
        #expect(model.rows.prefix(2).allSatisfy { $0.isFlagged })
        model.selectAll()
        #expect(model.selection == Set(model.rows.map(\.id)))
    }

    @Test("Priority inbox: Follow up, Important and Other across accounts; an answered follow-up drops out")
    func prioritySections() async throws {
        let mirror = try await MessageListMirror.seed()
        let second = try await mirror.addAccount(loginName: "luke", remoteId: 2)
        let sent = try await mirror.addMailbox(remoteId: 1007, name: "Sent")
        try await mirror.addMessages(sentAt: [Self.base + 1], firstRemoteId: 1, isImportant: true)
        try await mirror.addMessages(sentAt: [Self.base + 2], firstRemoteId: 2)
        try await mirror.addMessages(
            sentAt: [Self.base + 3], firstRemoteId: 3, into: second.inboxId, isImportant: true,
            account: second.accountId)
        let followUpIds = try await mirror.addMessages(
            sentAt: [Self.base + 4], firstRemoteId: 4, into: sent,
            tags: [TagWrite(remoteId: 50, imapLabel: "$follow_up", displayName: "Follow up")])
        // Recent: not yet four days old, so not a follow-up yet.
        try await mirror.addMessages(
            sentAt: [Int64(Date().timeIntervalSince1970)], firstRemoteId: 5, into: sent,
            tags: [TagWrite(remoteId: 50, imapLabel: "$follow_up", displayName: "Follow up")])
        let model = MessageListStore(store: mirror.store)
        var checked: [Int64] = []
        model.followUpCheck = { rows in checked += rows.map(\.id) }

        model.show(.priorityInbox, view: .flat)
        #expect(await waitUntil { model.sections.map(\.bucket) == [.followUp, .important, .other] })
        #expect(model.sections.map { $0.rows.count } == [1, 2, 1])
        #expect(Set(model.sections[1].rows.map(\.accountId)) == [mirror.accountId, second.accountId])
        #expect(model.sections.map(\.title) == ["Follow up", "Important", "Other"])
        #expect(model.sections.allSatisfy { $0.dateGroup == nil })
        #expect(checked == followUpIds)

        // The mirror's answer arrives as a row; the list hides the answered one.
        let account = try #require(try await mirror.store.account(id: mirror.accountId))
        let loginId = try #require(try await mirror.store.ensureLogin(account.identity).id)
        try await mirror.store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: "followUp", key: String(try #require(followUpIds.first)),
                payloadJSON: #"{"status":"ready","data":{"wasFollowedUp":true}}"#, fetchedAt: 1))
        #expect(await waitUntil { model.sections.map(\.bucket) == [.important, .other] })
    }

    @Test("Unified inbox merges every account's Inbox, newest first")
    func unifiedInbox() async throws {
        let mirror = try await MessageListMirror.seed()
        let second = try await mirror.addAccount(loginName: "luke", remoteId: 2)
        let archive = try await mirror.addMailbox(remoteId: 1006, name: "Archive")
        try await mirror.addMessages(sentAt: [Self.base + 1], firstRemoteId: 1)
        try await mirror.addMessages(
            sentAt: [Self.base + 2], firstRemoteId: 2, into: second.inboxId, account: second.accountId)
        try await mirror.addMessages(sentAt: [Self.base + 3], firstRemoteId: 3, into: archive)
        let model = MessageListStore(store: mirror.store)

        model.show(.unifiedInbox, view: .flat)
        #expect(await waitUntil { model.rows.count == 2 })
        #expect(model.rows.map(\.sentAt) == [Self.base + 2, Self.base + 1])
        #expect(model.title == "All inboxes")
        model.selection = [try #require(model.rows.first).id]
        #expect(model.focusedAccountId == second.accountId)
    }

    @Test("rows carry their tags, AI summary and draft flag; hidden labels stay hidden")
    func adornments() async throws {
        let mirror = try await MessageListMirror.seed()
        let ids = try await mirror.addMessages(
            sentAt: [Self.base + 1], firstRemoteId: 1, isDraft: true,
            tags: [
                TagWrite(remoteId: 1, imapLabel: "$label1", displayName: "Important"),
                TagWrite(remoteId: 2, imapLabel: "$label2", displayName: "Work", color: "#ff0000"),
                TagWrite(remoteId: 3, imapLabel: "notjunk", displayName: "NotJunk"),
            ])
        try await mirror.finishEnumerating()
        let id = try #require(ids.first)
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.tags[id]?.count == 3 })
        let row = try #require(model.rows.first)
        #expect(row.isDraft)
        #expect(model.adornments(for: row).tags.map(\.displayName) == ["Work"])
        #expect(model.adornments(for: row).preview == "Preview redacted")
        #expect(model.adornments(for: row).previewIsSummary == false)

        let account = try #require(try await mirror.store.account(id: mirror.accountId))
        let loginId = try #require(try await mirror.store.ensureLogin(account.identity).id)
        try await mirror.store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId, kind: "threadSummary", key: String(id),
                payloadJSON: #"{"status":"ready","data":"Summary redacted"}"#, fetchedAt: 1))
        #expect(await waitUntil { model.summaries[id] == "Summary redacted" })
        #expect(model.adornments(for: row).preview == "Summary redacted")
        #expect(model.adornments(for: row).previewIsSummary)
    }

    @Test("a drag carries the selected rows of the dragged row's mailbox, or the row alone")
    func dragPayload() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: (1...3).map { Self.base + $0 })
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 3 })
        let rows = model.rows

        model.selection = [rows[0].id, rows[1].id]
        let selected = model.dragPayload(for: rows[1])
        #expect(selected.messageIds == [rows[0].id, rows[1].id])
        #expect(selected.sourceMailboxId == mirror.mailboxId)
        #expect(selected.accountId == mirror.accountId)
        #expect(model.dragPayload(for: rows[2]).messageIds == [rows[2].id])
    }
}
