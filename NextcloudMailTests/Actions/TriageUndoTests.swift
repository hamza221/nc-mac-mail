// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// `⌘Z` after an accidental archive.
///
/// Undo is not a rollback: it is the inverse action, queued the same way, which is why it
/// works with the network off and why the server ends up being told both halves. The tests
/// assert the mirror, because the mirror is what the list draws.
@Suite("Triage undo")
@MainActor
struct TriageUndoTests {
    /// `UndoManager` coalesces registrations made in one run-loop pass, and the undo handler
    /// starts the database work in a `Task`. Yielding is what lets that task run; nothing here
    /// sleeps or reads a clock.
    private func settle() async {
        for _ in 0..<1000 { await Task.yield() }
    }

    @Test("undo puts an archived message back in the folder it came from")
    func undoArchive() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.archive(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.mailboxId == account.archiveId)

        #expect(actions.canUndo)
        actions.undo()
        await settle()

        #expect(try await mirror.message(id)?.mailboxId == account.inboxId)
        // Two promises, not none: the server is told about the archive and about the move
        // back, because it may already have heard the first.
        #expect(try await mirror.queueDepth(account) == 2)
    }

    @Test("redo archives it again")
    func redoAfterUndo() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.archive(Selection(messageIds: [id]))
        actions.undo()
        await settle()
        #expect(try await mirror.message(id)?.mailboxId == account.inboxId)

        #expect(actions.canRedo)
        actions.redo()
        await settle()

        #expect(try await mirror.message(id)?.mailboxId == account.archiveId)
    }

    @Test("undoing a move puts each message back in its own folder")
    func undoRestoresEachOrigin() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let fromInbox = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let fromJunk = try #require(
            try await mirror.addMessages(count: 1, account: account, mailboxId: account.junkId, firstRemoteId: 5).first
        )
        let trash = try #require(account.trashId)

        await actions.move(Selection(messageIds: [fromInbox, fromJunk]), to: trash)
        #expect(try await mirror.message(fromInbox)?.mailboxId == trash)
        #expect(try await mirror.message(fromJunk)?.mailboxId == trash)

        actions.undo()
        await settle()

        #expect(try await mirror.message(fromInbox)?.mailboxId == account.inboxId)
        #expect(try await mirror.message(fromJunk)?.mailboxId == account.junkId)
    }

    @Test("undoing a star on a mixed selection gives back the mix")
    func undoRestoresEachPreviousFlag() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let plain = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let starred = try #require(
            try await mirror.addMessages(count: 1, account: account, firstRemoteId: 2, flagged: true).first
        )

        await actions.toggleStar(Selection(messageIds: [plain, starred]))
        #expect(try await mirror.message(plain)?.isFlagged == true)

        actions.undo()
        await settle()

        #expect(try await mirror.message(plain)?.isFlagged == false)
        #expect(try await mirror.message(starred)?.isFlagged == true)
    }

    @Test("undoing junk clears the flag as well as the move")
    func undoJunkClearsTheFlag() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.junk(Selection(messageIds: [id]))
        actions.undo()
        await settle()

        let restored = try #require(try await mirror.message(id))
        #expect(restored.isJunk == false)
        #expect(restored.isNotJunk)
        #expect(restored.mailboxId == account.inboxId)
    }

    @Test("an erase has nothing to undo, and registers nothing rather than half a restore")
    func erasingLeavesNothingToUndo() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(
            try await mirror.addMessages(count: 1, account: account, mailboxId: account.trashId).first
        )

        await actions.delete(Selection(messageIds: [id]))

        #expect(try await mirror.message(id) == nil)
        #expect(actions.canUndo == false)
    }

    @Test("an action that changed nothing leaves the undo stack alone")
    func nothingQueuedMeansNothingToUndo() async throws {
        let mirror = try await TriageMirror.seed(accounts: [TriageMirror.Roles(archive: false)])
        let account = try #require(mirror.accounts.first)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.archive(Selection(messageIds: [id]))

        #expect(actions.canUndo == false)
    }
}
