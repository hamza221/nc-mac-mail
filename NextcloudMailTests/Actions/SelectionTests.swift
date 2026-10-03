// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// What a triage action acts on, and where the cursor goes afterwards.
@Suite("Selection")
@MainActor
struct SelectionTests {
    /// Real rows, read back through the same window the list opens, because `MessageRow` has
    /// no public initialiser outside `NCMailStore` and a hand-built one would be testing a
    /// struct this workstream did not write.
    private static func rows(count: Int) async throws -> (mirror: TriageMirror, rows: [MessageRow]) {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        try await mirror.addMessages(count: count, account: account)
        let rows = try await mirror.store.messages(mailboxId: account.inboxId, view: .flat, range: 0..<count)
        return (mirror, rows)
    }

    @Test("the selection follows the order the rows are drawn in, newest first")
    func orderFollowsTheRows() async throws {
        let (_, rows) = try await Self.rows(count: 4)
        let ids = rows.map(\.id)

        let selection = Selection(ids: Set(ids), orderedBy: rows, scope: .messages)

        #expect(selection.messageIds == ids)
    }

    @Test("an id the window no longer holds is kept, not dropped")
    func idsOutsideTheWindowSurvive() async throws {
        let (_, rows) = try await Self.rows(count: 3)
        let visible = try #require(rows.first)
        // The row newly arrived mail has pushed past the window's end: still selected,
        // missing from `selectedRows`. Dropping it would archive two of the three messages
        // the user chose and say nothing about the third.
        let pushedOut: Int64 = 9_999

        let selection = Selection(ids: [visible.id, pushedOut], orderedBy: [visible], scope: .messages)

        #expect(selection.messageIds == [visible.id, pushedOut])
    }

    @Test("the threaded view makes a row stand for its whole conversation")
    func scopeFollowsTheListView() {
        #expect(Selection.scope(for: .threaded) == .threads)
        #expect(Selection.scope(for: .flat) == .messages)
    }

    // MARK: - Advancing

    @Test("the cursor lands on the next row down, which is the next in sort order")
    func advanceGoesDown() async throws {
        let (_, rows) = try await Self.rows(count: 4)
        let ids = rows.map(\.id)

        #expect(MessageActions.nextSelection(after: [ids[1]], in: rows) == ids[2])
    }

    @Test("acting on the last row falls back to the one above it")
    func advanceStopsAtTheEnd() async throws {
        let (_, rows) = try await Self.rows(count: 3)
        let ids = rows.map(\.id)

        #expect(MessageActions.nextSelection(after: [ids[2]], in: rows) == ids[1])
    }

    @Test("a multi-selection advances past the last of it, skipping the rest of it")
    func advanceSkipsTheWholeSelection() async throws {
        let (_, rows) = try await Self.rows(count: 5)
        let ids = rows.map(\.id)

        #expect(MessageActions.nextSelection(after: [ids[1], ids[2]], in: rows) == ids[3])
    }

    @Test("acting on every row leaves nothing selected")
    func advanceFromAWholeListSelectsNothing() async throws {
        let (_, rows) = try await Self.rows(count: 3)

        #expect(MessageActions.nextSelection(after: Set(rows.map(\.id)), in: rows) == nil)
    }

    @Test("an id that is not on screen moves nothing")
    func advanceFromAnUnknownIdIsNil() async throws {
        let (_, rows) = try await Self.rows(count: 3)

        #expect(MessageActions.nextSelection(after: [9_999], in: rows) == nil)
    }

    // MARK: - Through an action

    @Test("archiving advances the selection; starring leaves it where it is")
    func onlyRemovingActionsAdvance() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        try await mirror.addMessages(count: 3, account: account)
        let rows = try await mirror.store.messages(mailboxId: account.inboxId, view: .flat, range: 0..<3)
        let ids = rows.map(\.id)
        let list = StubSelectionSource(rows: rows, selection: [ids[0]])
        let actions = MessageActions(store: mirror.store)
        actions.list = list

        await actions.toggleStar(Selection(messageIds: [ids[0]]))
        #expect(list.selection == [ids[0]])

        await actions.archive(Selection(messageIds: [ids[0]]))
        #expect(list.selection == [ids[1]])
    }
}
