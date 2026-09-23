// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// Triage against a real mirror.
///
/// **No transport is named anywhere in this file, and that is an assertion rather than an
/// omission.** Every test below acts, then reads the database back. If a triage action needed
/// the network to change what the list shows, none of them could pass — which is
/// `CLAUDE.md`'s one invariant, stated as a test. The queue rows the actions leave behind are
/// the promise to tell the server; nothing here drains them, which is exactly the offline
/// case.
@Suite("Message actions")
@MainActor
struct MessageActionsTests {
    private static func oneAccount(
        _ roles: TriageMirror.Roles = .all
    ) async throws -> (
        mirror: TriageMirror, account: TriageMirror.Account, actions: MessageActions
    ) {
        let mirror = try await TriageMirror.seed(accounts: [roles])
        let account = try #require(mirror.accounts.first)
        return (mirror, account, MessageActions(store: mirror.store))
    }

    // MARK: - Archive

    @Test("archive moves the message locally and queues one operation, with no network in reach")
    func archiveWritesTheMirrorAndTheQueue() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 1, account: account)
        let id = try #require(ids.first)

        await actions.archive(Selection(messageIds: [id]))

        let archived = try #require(try await mirror.message(id))
        #expect(archived.mailboxId == account.archiveId)
        #expect(try await mirror.queueDepth(account) == 1)
    }

    @Test("archive resolves the folder from the account that owns the message, not the selected one")
    func archiveRoutesEachAccountToItsOwnFolder() async throws {
        let mirror = try await TriageMirror.seed(accounts: [.all, .all])
        let first = try #require(mirror.accounts.first)
        let second = try #require(mirror.accounts.last)
        let actions = MessageActions(store: mirror.store)
        let a = try #require(try await mirror.addMessages(count: 1, account: first).first)
        let b = try #require(try await mirror.addMessages(count: 1, account: second).first)

        await actions.archive(Selection(messageIds: [a, b]))

        #expect(try await mirror.message(a)?.mailboxId == first.archiveId)
        #expect(try await mirror.message(b)?.mailboxId == second.archiveId)
        // And each one is a separate promise, because they are separate accounts' queues.
        #expect(try await mirror.queueDepth(first) == 1)
        #expect(try await mirror.queueDepth(second) == 1)
    }

    @Test("an account with no archive folder changes nothing and says why")
    func archiveWithNoArchiveFolderIsRefusedWithAReason() async throws {
        let (mirror, account, actions) = try await Self.oneAccount(TriageMirror.Roles(archive: false))
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let selection = Selection(messageIds: [id])

        await actions.refreshAvailability(for: selection)
        await actions.archive(selection)

        #expect(try await mirror.message(id)?.mailboxId == account.inboxId)
        #expect(try await mirror.queueDepth(account) == 0)
        let availability = try #require(actions.availability[.archive])
        #expect(availability.isAvailable == false)
        let reason = try #require(availability.reason)
        #expect(reason.contains("Archive"))
        #expect(reason.contains("Account 0"))
    }

    @Test("archiving one message of a mixed selection still archives the other")
    func archiveSkipsOnlyTheAccountThatCannot() async throws {
        let mirror = try await TriageMirror.seed(accounts: [.all, TriageMirror.Roles(archive: false)])
        let withArchive = try #require(mirror.accounts.first)
        let without = try #require(mirror.accounts.last)
        let actions = MessageActions(store: mirror.store)
        let a = try #require(try await mirror.addMessages(count: 1, account: withArchive).first)
        let b = try #require(try await mirror.addMessages(count: 1, account: without).first)

        await actions.archive(Selection(messageIds: [a, b]))

        #expect(try await mirror.message(a)?.mailboxId == withArchive.archiveId)
        #expect(try await mirror.message(b)?.mailboxId == without.inboxId)
    }

    // MARK: - Delete

    @Test("delete moves to trash, and erases a message already in it")
    func deleteTrashesThenErases() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.delete(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.mailboxId == account.trashId)

        await actions.delete(Selection(messageIds: [id]))
        #expect(try await mirror.message(id) == nil)
    }

    // MARK: - Junk

    @Test("junk sets the flag and moves, as two operations in that order")
    func junkFlagsThenMoves() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.junk(Selection(messageIds: [id]))

        let junked = try #require(try await mirror.message(id))
        #expect(junked.isJunk)
        #expect(junked.isNotJunk == false)
        #expect(junked.mailboxId == account.junkId)
        let queued = try await mirror.store.pendingOperations(accountId: account.id)
        #expect(queued.map(\.kind) == ["setFlags", "move"])
    }

    // MARK: - Toggles

    @Test("a mixed selection is starred, and a wholly starred one is unstarred")
    func starTogglesOnTheWholeSelection() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let plain = try #require(try await mirror.addMessages(count: 1, account: account).first)
        let starred = try #require(
            try await mirror.addMessages(count: 1, account: account, firstRemoteId: 2, flagged: true).first
        )
        let selection = Selection(messageIds: [plain, starred])

        await actions.toggleStar(selection)
        #expect(try await mirror.message(plain)?.isFlagged == true)
        #expect(try await mirror.message(starred)?.isFlagged == true)

        await actions.toggleStar(selection)
        #expect(try await mirror.message(plain)?.isFlagged == false)
        #expect(try await mirror.message(starred)?.isFlagged == false)
    }

    @Test("U on an unread message marks it read, and again marks it unread")
    func unreadTogglesThroughSeen() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.toggleUnread(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.isSeen == true)

        await actions.toggleUnread(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.isSeen == false)
    }

    @Test("important is the same rule over its own column")
    func importantToggles() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.toggleImportant(Selection(messageIds: [id]))
        #expect(try await mirror.message(id)?.isImportant == true)
    }

    // MARK: - Threads

    @Test("in the threaded view one row acts on every message of its thread")
    func threadScopeActsOnEveryMember() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 4, account: account, threadRootId: "<root@example.invalid>")
        let newest = try #require(ids.last)

        await actions.archive(Selection(messageIds: [newest], scope: .threads))

        for id in ids {
            #expect(try await mirror.message(id)?.mailboxId == account.archiveId)
        }
        // One `moveThread` row, not four: the thread endpoint takes any member and resolves
        // the root itself.
        #expect(try await mirror.queueDepth(account) == 1)
    }

    @Test("a thread's flags are set one message at a time, because there is no thread flag route")
    func threadFlagsExpandToMembers() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let ids = try await mirror.addMessages(count: 3, account: account, threadRootId: "<root@example.invalid>")
        let newest = try #require(ids.last)

        await actions.toggleUnread(Selection(messageIds: [newest], scope: .threads))

        for id in ids {
            #expect(try await mirror.message(id)?.isSeen == true)
        }
        #expect(try await mirror.queueDepth(account) == 3)
    }

    // MARK: - Move

    @Test("move refuses a folder belonging to another account")
    func moveAcrossAccountsIsRefused() async throws {
        let mirror = try await TriageMirror.seed(accounts: [.all, .all])
        let first = try #require(mirror.accounts.first)
        let second = try #require(mirror.accounts.last)
        let actions = MessageActions(store: mirror.store)
        let id = try #require(try await mirror.addMessages(count: 1, account: first).first)

        await actions.move(Selection(messageIds: [id]), to: try #require(second.archiveId))

        #expect(try await mirror.message(id)?.mailboxId == first.inboxId)
        #expect(try await mirror.queueDepth(first) == 0)
    }

    @Test("a selection spanning two accounts disables Move with a reason")
    func moveIsUnavailableAcrossAccounts() async throws {
        let mirror = try await TriageMirror.seed(accounts: [.all, .all])
        let first = try #require(mirror.accounts.first)
        let second = try #require(mirror.accounts.last)
        let actions = MessageActions(store: mirror.store)
        let a = try #require(try await mirror.addMessages(count: 1, account: first).first)
        let b = try #require(try await mirror.addMessages(count: 1, account: second).first)

        await actions.refreshAvailability(for: Selection(messageIds: [a, b]))

        #expect(actions.availability[.move]?.isAvailable == false)
        #expect(actions.selectionAccountIds == [first.id, second.id].sorted())
    }

    // MARK: - Mark all as read

    @Test("mark all as read touches only the unread messages of that mailbox")
    func markAllReadQueuesOnlyTheUnread() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let unread = try await mirror.addMessages(count: 3, account: account)
        try await mirror.addMessages(count: 2, account: account, firstRemoteId: 10, seen: true)
        let elsewhere = try #require(
            try await mirror.addMessages(
                count: 1,
                account: account,
                mailboxId: account.archiveId,
                firstRemoteId: 20
            ).first
        )

        await actions.markAllRead(mailboxId: account.inboxId)

        for id in unread {
            #expect(try await mirror.message(id)?.isSeen == true)
        }
        #expect(try await mirror.message(elsewhere)?.isSeen == false)
        // Three rows, one per unread message: the server has no mark-all-read route.
        #expect(try await mirror.queueDepth(account) == 3)
    }

    @Test("mark all as read on a mailbox with nothing unread queues nothing")
    func markAllReadOnAReadMailboxIsANoOp() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        try await mirror.addMessages(count: 2, account: account, seen: true)

        await actions.markAllRead(mailboxId: account.inboxId)

        #expect(try await mirror.queueDepth(account) == 0)
    }

    // MARK: - Ids the mirror has lost

    @Test("an id the mirror no longer has is skipped rather than queued")
    func missingMessagesAreSkipped() async throws {
        let (mirror, account, actions) = try await Self.oneAccount()
        let id = try #require(try await mirror.addMessages(count: 1, account: account).first)

        await actions.archive(Selection(messageIds: [id, id + 9_999]))

        #expect(try await mirror.message(id)?.mailboxId == account.archiveId)
        #expect(try await mirror.queueDepth(account) == 1)
    }
}
