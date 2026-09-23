// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NextcloudUI
import SwiftUI
import Testing

@testable import NextcloudMail

/// The shortcut table, and the promise that every key in it is discoverable.
@Suite("Triage commands")
@MainActor
struct TriageCommandsTests {
    @Test("every key in the specification's table is bound exactly once")
    func theTableMatchesTheSpecification() {
        let bound = TriageAction.allCases.compactMap { action in
            action.shortcut.map { NCKeyboardShortcutGlyphs.string(for: $0) }
        }
        // ux-spec.md#keyboard, minus the rows the platform owns: ↑, ↓, ⇧-click, Space and
        // ⌘, all belong to `List`, the WebView and the system.
        // Shift before Command: Apple's canonical modifier order is Control, Option, Shift,
        // Command, so `⌘⇧F` in the specification's prose renders as `⇧⌘F` on the key cap.
        #expect(Set(bound) == ["A", "S", "U", "J", "\u{232B}", "R", "\u{2190}", "\u{2192}", "⌘P", "⌘F", "⇧⌘F"])
        #expect(bound.count == Set(bound).count)
    }

    @Test("the shortcut list shows every bound key, and the ones the platform owns")
    func helpListsEverything() {
        let rows = KeyboardShortcutRow.all
        let bound = TriageAction.allCases.filter { $0.shortcut != nil }

        for action in bound {
            #expect(rows.contains { $0.id == action.rawValue })
        }
        #expect(rows.count == bound.count + KeyboardShortcutRow.platform.count)
        // Every line reads aloud as words rather than as punctuation.
        #expect(rows.allSatisfy { !$0.spoken.isEmpty && !$0.action.isEmpty })
    }

    @Test("a tooltip carries the key, and the reason when there is one")
    func helpTextCarriesTheKeyAndTheReason() {
        #expect(TriageAction.archive.help(reason: nil) == "Archive (A)")
        #expect(TriageAction.archive.help(reason: "No Archive folder.").hasSuffix("No Archive folder."))
        // No key, no brackets.
        #expect(TriageAction.markAllRead.help(reason: nil) == TriageAction.markAllRead.title)
    }

    @Test("only the actions that empty a row advance the selection")
    func removalIsWhatMovesTheCursor() {
        #expect(TriageAction.archive.removesFromList)
        #expect(TriageAction.delete.removesFromList)
        #expect(TriageAction.junk.removesFromList)
        #expect(TriageAction.move.removesFromList)
        #expect(TriageAction.star.removesFromList == false)
        #expect(TriageAction.unread.removesFromList == false)
    }

    // MARK: - The context

    @Test("a command with no handler is not offered")
    func unwiredCommandsAreDisabled() async throws {
        let mirror = try await TriageMirror.seed()
        let context = TriageContext(store: mirror.store)

        #expect(context.isEnabled(.refresh) == false)
        #expect(context.isEnabled(.search) == false)
        #expect(context.isEnabled(.printMessage) == false)

        context.refresh = {}
        #expect(context.isEnabled(.refresh))
    }

    @Test("with nothing selected, every triage action is off")
    func noSelectionDisablesTriage() async throws {
        let mirror = try await TriageMirror.seed()
        let context = TriageContext(store: mirror.store)

        #expect(context.hasSelection == false)
        for action in [TriageAction.archive, .delete, .junk, .star, .unread, .important, .move] {
            #expect(context.isEnabled(action) == false)
        }
    }

    @Test("← and → walk the list, and either one enters it from nothing")
    func arrowsStepThroughTheList() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        try await mirror.addMessages(count: 3, account: account)
        let rows = try await mirror.store.messages(mailboxId: account.inboxId, view: .flat, range: 0..<3)
        let ids = rows.map(\.id)

        let listStore = MessageListStore(store: mirror.store)
        let context = TriageContext(store: mirror.store)
        context.listStore = listStore
        listStore.show(mailbox: account.inboxId, view: .flat)
        #expect(await waitUntil { listStore.rows.count == 3 })

        await context.perform(.nextMessage)
        #expect(listStore.selection == [ids[0]])

        await context.perform(.nextMessage)
        #expect(listStore.selection == [ids[1]])

        await context.perform(.previousMessage)
        #expect(listStore.selection == [ids[0]])

        // And it stops at the top rather than wrapping round to the bottom.
        await context.perform(.previousMessage)
        #expect(listStore.selection == [ids[0]])
    }

    @Test("the context acts on the ids the user chose, in the rows' order")
    func theContextBuildsItsSelectionFromTheIds() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        try await mirror.addMessages(count: 3, account: account)

        let listStore = MessageListStore(store: mirror.store)
        let context = TriageContext(store: mirror.store)
        context.listStore = listStore
        listStore.show(mailbox: account.inboxId, view: .flat)
        #expect(await waitUntil { listStore.rows.count == 3 })
        let ids = listStore.rows.map(\.id)
        listStore.selection = [ids[2], ids[0]]

        #expect(context.selection.messageIds == [ids[0], ids[2]])

        await context.perform(.archive)
        #expect(try await mirror.message(ids[0])?.mailboxId == account.archiveId)
        #expect(try await mirror.message(ids[2])?.mailboxId == account.archiveId)
        #expect(try await mirror.message(ids[1])?.mailboxId == account.inboxId)
    }

    @Test("the move list offers one account's folders, and nothing across two")
    func moveDestinationsFollowTheSelection() async throws {
        let mirror = try await TriageMirror.seed(accounts: [.all, .all])
        let first = try #require(mirror.accounts.first)
        let second = try #require(mirror.accounts.last)
        let context = TriageContext(store: mirror.store)
        let a = try #require(try await mirror.addMessages(count: 1, account: first).first)
        let b = try #require(try await mirror.addMessages(count: 1, account: second).first)

        await context.actions.refreshAvailability(for: Selection(messageIds: [a]))
        let single = await context.moveDestinations()
        #expect(
            single.map(\.id).sorted()
                == [first.inboxId, first.archiveId, first.junkId, first.trashId].compactMap { $0 }.sorted())

        await context.actions.refreshAvailability(for: Selection(messageIds: [a, b]))
        #expect(await context.moveDestinations().isEmpty)
    }
}
