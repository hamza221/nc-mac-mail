// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NextcloudUI
import Testing

@testable import NextcloudMail

/// Triage v2 (WS-31) against a real in-memory mirror with no transport anywhere: every
/// action here is the offline case — the mirror changes, the queue grows, nothing drains.
@Suite("Triage v2")
@MainActor
struct TriageV2Tests {
    private func settle() async {
        for _ in 0..<1000 { await Task.yield() }
    }

    /// One user action as one undo group. `UndoManager` groups by run-loop pass, and a test
    /// that awaits two actions back to back can land both in one pass — undoing both at once,
    /// which a person clicking twice never sees. Explicit groups make the boundary the test's.
    private func userAction(_ actions: MessageActions, _ body: () async -> Void) async {
        actions.undoManager.groupsByEvent = false
        actions.undoManager.beginUndoGrouping()
        await body()
        actions.undoManager.endUndoGrouping()
    }

    private static func oneAccount(
        _ roles: TriageMirror.Roles = .all
    ) async throws -> (mirror: TriageMirror, account: TriageMirror.Account, actions: MessageActions) {
        let mirror = try await TriageMirror.seed(accounts: [roles])
        let account = try #require(mirror.accounts.first)
        return (mirror, account, MessageActions(store: mirror.store))
    }

    private func kinds(_ mirror: TriageMirror, _ account: TriageMirror.Account) async throws -> [String] {
        try await mirror.store.pendingOperations(accountId: account.id).map(\.kind)
    }

    // MARK: - Spam

    @Test("mark as spam flags, marks read, clears important, moves to Junk; undo restores all of it")
    func spamAndUndo() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account, important: true).first)

        await actions.junk(Selection(messageIds: [id]))

        let junked = try #require(try await mirror.message(id))
        #expect(junked.isJunk && !junked.isNotJunk)
        #expect(junked.isSeen)
        #expect(junked.isImportant == false)
        #expect(junked.mailboxId == account.junkId)
        #expect(try await kinds(mirror, account) == ["setFlags", "setFlags", "move"])

        actions.undo()
        await settle()
        let restored = try #require(try await mirror.message(id))
        #expect(restored.mailboxId == account.inboxId)
        #expect(restored.isJunk == false)
        #expect(restored.isSeen == false)
        #expect(restored.isImportant)
    }

    @Test("a selection that is all junk is marked not spam and goes back to the Inbox")
    func notSpam() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        await actions.junk(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.mailboxId == account.junkId)

        await actions.refreshAvailability(for: Selection(messageIds: [id]))
        #expect(actions.selectionIsJunk)
        await actions.junk(Selection(messageIds: [id]))

        let back = try #require(try await mirror.message(id))
        #expect(back.isJunk == false)
        #expect(back.isNotJunk)
        #expect(back.mailboxId == account.inboxId)
    }

    // MARK: - Tags

    @Test("a tag created offline can be set at once, toggled off, and the unset undone")
    func tagLifecycleOffline() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 2, account: account)
        let selection = Selection(messageIds: ids)

        await actions.createTag(accountId: account.id, displayName: " Invoices ", color: "#00ff00")
        let tag = try #require(
            try await mirror.store.tags(accountId: account.id).first { $0.displayName == "Invoices" })
        // ADR-0081: a placeholder until the drain swaps it.
        #expect(tag.remoteId < 0)

        await userAction(actions) { await actions.toggleTag(tag, on: selection) }
        #expect(await actions.labelsOnAll(selection) == [tag.imapLabel])

        await userAction(actions) { await actions.toggleTag(tag, on: selection) }
        #expect(await actions.labelsOnAll(selection).isEmpty)

        actions.undo()
        await settle()
        let restored = await actions.labelsOnAll(selection)
        #expect(restored == [tag.imapLabel])
        let queued = try await kinds(mirror, account)
        #expect(queued == ["createTag", "setTag", "setTag", "unsetTag", "unsetTag", "setTag", "setTag"])
    }

    @Test("a mixed selection is tagged everywhere; untagging restores only the ones that lacked it")
    func tagMixedSelection() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 2, account: account)
        await actions.createTag(accountId: account.id, displayName: "Work2", color: "#123456")
        let tag = try #require(try await mirror.store.tags(accountId: account.id).first)

        await userAction(actions) { await actions.setTag(tag, present: true, on: Selection(messageIds: [ids[0]])) }
        await userAction(actions) { await actions.toggleTag(tag, on: Selection(messageIds: ids)) }
        #expect(await actions.labelsOnAll(Selection(messageIds: ids)) == [tag.imapLabel])

        actions.undo()
        await settle()
        let labels = try await mirror.store.messageTagLabels(messageIds: ids)
        #expect(labels[ids[0]] == [tag.imapLabel])
        #expect((labels[ids[1]] ?? []).isEmpty)
    }

    @Test("rename and delete go through the queue")
    func tagEditAndDelete() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        await actions.createTag(accountId: account.id, displayName: "Old", color: "#000000")
        let tag = try #require(try await mirror.store.tags(accountId: account.id).first)

        await actions.updateTag(tag, displayName: "New", color: "#ffffff")
        let renamed = try #require(try await mirror.store.tags(accountId: account.id).first)
        #expect(renamed.displayName == "New")
        #expect(renamed.color == "#ffffff")

        await actions.deleteTag(renamed)
        #expect(try await mirror.store.tags(accountId: account.id).isEmpty)
        #expect(try await kinds(mirror, account) == ["createTag", "updateTag", "deleteTag"])
    }

    @Test("the modal's order, hiding and validation follow the web")
    func tagRules() {
        func tag(_ id: Int64, _ label: String, _ name: String) -> TagRecord {
            TagRecord(id: id, accountId: 1, remoteId: id, imapLabel: label, displayName: name)
        }
        let tags = [
            tag(1, "$label1", "Important"), tag(2, "$label2", "Work"), tag(3, "$label3", "Personal"),
            tag(4, "$label4", "To Do"), tag(5, "$label5", "Later"), tag(6, "zz", "Zebra"),
            tag(7, "aa", "apple"), tag(8, "x", "Forwarded"), tag(9, "set", "Mango"),
        ]
        let ordered = TagRules.ordered(tags, setOnAll: ["set"]).map(\.displayName)
        #expect(ordered == ["Work", "To Do", "Personal", "Later", "Mango", "apple", "Zebra"])

        #expect(TagRules.validate("  ", among: tags) == .empty)
        #expect(TagRules.validate("NotJunk", among: tags) == .hidden)
        #expect(TagRules.validate("work", among: tags) == .duplicate)
        #expect(TagRules.validate("Work", editing: tags[1], among: tags) == nil)
        #expect(TagRules.validate("Receipts", among: tags) == nil)

        var generator = SystemRandomNumberGenerator()
        let color = TagRules.randomColor(using: &generator)
        #expect(color.count == 7 && color.hasPrefix("#") && NCRGB(hex: color) != nil)
    }

    // MARK: - Snooze presets

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    /// 2026-10-05 is a Monday.
    private static func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func presets(day: Int, hour: Int, minute: Int = 0) -> [SnoozeOption.Preset: Date] {
        Dictionary(
            uniqueKeysWithValues: SnoozePresets.options(
                now: date(day: day, hour: hour, minute: minute), calendar: calendar
            )
            .map { ($0.preset, $0.date) })
    }

    @Test("Monday morning: every preset, on the hour")
    func presetsMonday() {
        let options = Self.presets(day: 5, hour: 9, minute: 37)
        #expect(options[.laterToday] == Self.date(day: 5, hour: 18))
        #expect(options[.tomorrow] == Self.date(day: 6, hour: 8))
        #expect(options[.thisWeekend] == Self.date(day: 10, hour: 8))
        #expect(options[.nextWeek] == Self.date(day: 12, hour: 8))
        #expect(
            SnoozePresets.options(now: Self.date(day: 5, hour: 9), calendar: Self.calendar).map(\.preset)
                == [.laterToday, .tomorrow, .thisWeekend, .nextWeek])
    }

    @Test("Later today disappears at 17:00, not before")
    func laterTodayCutoff() {
        #expect(Self.presets(day: 5, hour: 16, minute: 59)[.laterToday] != nil)
        #expect(Self.presets(day: 5, hour: 17)[.laterToday] == nil)
    }

    @Test("This weekend is offered Monday to Thursday only")
    func weekendDays() {
        #expect(Self.presets(day: 8, hour: 10)[.thisWeekend] == Self.date(day: 10, hour: 8))  // Thursday
        #expect(Self.presets(day: 9, hour: 10)[.thisWeekend] == nil)  // Friday
        #expect(Self.presets(day: 10, hour: 10)[.thisWeekend] == nil)  // Saturday
        #expect(Self.presets(day: 11, hour: 10)[.thisWeekend] == nil)  // Sunday
    }

    @Test("Next week is the coming Monday, every day but Sunday")
    func nextWeekDays() {
        #expect(Self.presets(day: 9, hour: 10)[.nextWeek] == Self.date(day: 12, hour: 8))  // Friday
        #expect(Self.presets(day: 10, hour: 23)[.nextWeek] == Self.date(day: 12, hour: 8))  // Saturday
        #expect(Self.presets(day: 11, hour: 10)[.nextWeek] == nil)  // Sunday
        #expect(Self.presets(day: 11, hour: 10)[.tomorrow] == Self.date(day: 12, hour: 8))
    }

    // MARK: - Snooze

    @Test("the first snooze creates the Snoozed folder, offline, then reuses it")
    func snoozeCreatesFolderOnFirstUse() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 2, account: account)
        let until: Int64 = 1_900_000_000

        await actions.snooze(Selection(messageIds: [ids[0]]), until: until)

        let snoozed = try #require(
            try await mirror.store.mailboxes(accountId: account.id).first { $0.name == "Snoozed" })
        #expect(snoozed.remoteId < 0)
        #expect(try await mirror.store.account(id: account.id)?.snoozeMailboxId == snoozed.remoteId)
        #expect(try await mirror.message(ids[0])?.mailboxId == snoozed.id)
        #expect(try await mirror.store.snoozeUntil(messageId: ids[0]) == until)
        #expect(try await kinds(mirror, account) == ["createMailbox", "patchAccount", "snooze"])

        await actions.snooze(Selection(messageIds: [ids[1]]), until: until)
        #expect(try await mirror.store.mailboxes(accountId: account.id).filter { $0.name == "Snoozed" }.count == 1)
        #expect(try await kinds(mirror, account).filter { $0 == "createMailbox" }.count == 1)

        await actions.refreshAvailability(for: Selection(messageIds: ids))
        #expect(actions.selectionIsSnoozed)
        #expect(actions.availability[.unsnooze]?.isAvailable == true)
        #expect(actions.availability[.snooze]?.isAvailable == false)
    }

    @Test("snooze is undone by an unsnooze that puts the message back")
    func snoozeUndo() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.snooze(Selection(messageIds: [id]), until: 1_900_000_000)
        actions.undo()
        await settle()

        #expect(try await mirror.message(id)?.mailboxId == account.inboxId)
        #expect(try await mirror.store.snoozeUntil(messageId: id) == nil)
        #expect(try await kinds(mirror, account).last == "unsnooze")
    }

    @Test("unsnooze queues one operation per thread in the threaded view")
    func unsnoozeThreads() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 2, account: account, threadRootId: "<root@example.invalid>")
        await actions.snooze(Selection(messageIds: [ids[0]], scope: .threads), until: 1_900_000_000)
        #expect(try await kinds(mirror, account).last == "snoozeThread")

        await actions.unsnooze(Selection(messageIds: [ids[0]], scope: .threads))
        #expect(try await kinds(mirror, account).last == "unsnoozeThread")
        #expect(try await mirror.store.snoozeUntil(messageId: ids[1]) == nil)
    }

    // MARK: - Quick actions

    private func addQuickAction(
        _ mirror: TriageMirror, account: TriageMirror.Account, steps: [(String, Int64?, Int64?)]
    ) async throws {
        let written = try await mirror.store.replaceQuickActions(
            [QuickActionRecord(accountId: account.id, remoteId: 7, name: "Process")], accountId: account.id)
        let actionId = try #require(written.first?.id)
        try await mirror.store.replaceQuickActionSteps(
            steps.enumerated().map { index, step in
                QuickActionStepRecord(
                    quickActionId: actionId, remoteId: Int64(index + 1), name: step.0, position: index,
                    tagRemoteId: step.1, mailboxRemoteId: step.2)
            },
            quickActionId: actionId)
    }

    @Test("a quick action runs its steps in order, offline, and undoes as one")
    func quickActionRunsAndUndoes() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let archiveId = try #require(account.archiveId)
        let archiveRemote = try #require(try await mirror.store.mailbox(id: archiveId)?.remoteId)
        try await addQuickAction(
            mirror, account: account,
            steps: [("markAsRead", nil, nil), ("markAsFavorite", nil, nil), ("moveThread", nil, archiveRemote)])

        let selection = Selection(messageIds: [id])
        let runnable = try #require(await actions.quickActions(for: selection).first)
        await actions.run(runnable, on: selection)

        let after = try #require(try await mirror.message(id))
        #expect(after.isSeen && after.isFlagged)
        #expect(after.mailboxId == account.archiveId)

        actions.undo()
        await settle()
        let undone = try #require(try await mirror.message(id))
        #expect(undone.mailboxId == account.inboxId)
        #expect(!undone.isSeen && !undone.isFlagged)
    }

    @Test("a step whose tag has gone warns and the rest still run")
    func quickActionMissingTag() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        try await addQuickAction(
            mirror, account: account, steps: [("applyTag", 999, nil), ("markAsImportant", nil, nil)])

        let selection = Selection(messageIds: [id])
        let runnable = try #require(await actions.quickActions(for: selection).first)
        await actions.run(runnable, on: selection)

        #expect(actions.notice == "Could not apply tag, configured tag not found")
        #expect(try await mirror.message(id)?.isImportant == true)
    }

    @Test("quick actions are filtered by the source folder's ACL")
    func quickActionACL() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let shared = try await mirror.store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: 50, name: "Shared", delimiter: ".", displayName: "Shared",
                    isSubscribed: true, rawJSON: #"{"myAcls":"lrs"}"#)
            ],
            accountId: account.id)
        let sharedId = try #require(shared.first?.id)
        let id = try #require(try await mirror.addMessages(count: 1, account: account, mailboxId: sharedId).first)

        try await addQuickAction(mirror, account: account, steps: [("markAsRead", nil, nil)])
        #expect(await actions.quickActions(for: Selection(messageIds: [id])).count == 1)

        try await addQuickAction(
            mirror, account: account, steps: [("markAsRead", nil, nil), ("deleteThread", nil, nil)])
        #expect(await actions.quickActions(for: Selection(messageIds: [id])).isEmpty)

        #expect(MailboxRights(acls: nil).canDelete)
        #expect(MailboxRights(acls: "lrswi").canDelete == false)
        #expect(MailboxRights(acls: "lrswite").canDelete)
    }

    @Test("the inline picker offers only folders that take a message, indented by depth")
    func inlinePickerOptions() async throws {
        let (mirror, account, _) = try await Self.oneAccount()
        try await mirror.store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: 60, name: "INBOX.Child", delimiter: ".", displayName: "Child",
                    isSubscribed: true),
                MailboxWrite(
                    accountId: account.id, remoteId: 61, name: "ReadOnly", delimiter: ".", displayName: "ReadOnly",
                    isSubscribed: true, rawJSON: #"{"myAcls":"lr"}"#),
            ],
            accountId: account.id)

        let options = await InlineMailboxPicker.options(accountId: account.id, store: mirror.store)
        #expect(options.contains { $0.displayName == "Child" && $0.depth == 1 })
        #expect(!options.contains { $0.displayName == "ReadOnly" })
        #expect(options.contains { $0.id == account.inboxId && $0.depth == 0 })
    }

    // MARK: - Context

    @Test("forward as attachment and edit as new open the composer with the verbatim requests")
    func composerRequests() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let ids = try await mirror.addMessages(count: 2, account: account)
        let context = TriageContext(store: mirror.store)
        var opened: [ComposeRequest] = []
        context.openComposer = { opened.append($0) }

        await context.perform(.forwardAsAttachment, on: Set(ids))
        await context.perform(.editAsNew, on: [ids[0]])
        #expect(opened.count == 2)
        if case .forward(let forwarded, let asAttachment) = opened.first {
            #expect(Set(forwarded) == Set(ids))
            #expect(asAttachment)
        } else {
            Issue.record("expected a forward request")
        }
        #expect(opened.last == .editAsNew(messageId: ids[0]))
    }

    @Test("acting on hovered rows leaves the selection alone")
    func hoverDoesNotSelect() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let context = TriageContext(store: mirror.store)

        await context.perform(.star, on: [id])
        #expect(try await mirror.message(id)?.isFlagged == true)
        #expect(context.selection.isEmpty)
    }

    @Test("Edit Tags, Move and Snooze… open their sheets for the selection")
    func sheetsOpen() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let context = TriageContext(store: mirror.store)
        let selection = Selection(messageIds: [id], scope: .threads)

        await context.perform(.editTags, on: [id])
        #expect(context.presentation == .tags(selection, accountId: account.id))
        await context.perform(.move, on: [id])
        #expect(context.presentation == .move(selection))
        await context.perform(.snooze, on: [id])
        #expect(context.presentation == .customSnooze(selection))
    }
}
