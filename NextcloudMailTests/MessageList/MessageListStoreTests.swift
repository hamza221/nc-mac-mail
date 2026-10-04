// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// The message list against a real mirror.
///
/// Nothing is mocked below `MailStore`, so "the list is the database" is asserted rather than
/// described, and "the list never fetches" is a fact about the link line: `NCMailStore`
/// cannot see `NCMailNet`, and this file names neither a transport nor a client.
@Suite("Message list store")
@MainActor
struct MessageListStoreTests {
    /// Ten messages, one second apart, every third one read.
    private static func mirrorWithTen() async throws -> MessageListMirror {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: (1...10).map { 1_700_000_000 + Int64($0) }, seenEvery: 3)
        try await mirror.finishEnumerating()
        return mirror
    }

    // MARK: - Rows

    @Test("selecting a mailbox fills the list from the database")
    func selectionFillsTheList() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        // Newest first, which is what `idxMessageMailboxSent` is walked for.
        #expect(model.rows.map(\.sentAt) == (1...10).reversed().map { 1_700_000_000 + Int64($0) })
        #expect(model.presentation == .rows)
        #expect(model.hasMore == false)
    }

    @Test("a row carries the server's id, because WS-10 builds its requests from one")
    func rowsCarryTheRemoteId() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { !model.rows.isEmpty })
        let newest = try #require(model.rows.first)
        #expect(newest.remoteId == 10)
        #expect(newest.id != newest.remoteId || newest.mailboxId == mirror.mailboxId)
    }

    @Test("a flag written by sync reaches the row without anything asking for it")
    func rowsUpdateLiveWhenSyncWrites() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        #expect(try #require(model.rows.first).isSeen == false)

        // The same envelope again with the read flag set: exactly what an incremental sync
        // writes when someone opens the message in the web client.
        try await mirror.addMessages(sentAt: [1_700_000_010], firstRemoteId: 10, seenEvery: 1)

        #expect(await waitUntil { model.rows.first?.isSeen == true })
        #expect(model.rows.first?.threadUnreadCount == 0)
    }

    // MARK: - Threaded and flat

    @Test("threaded shows one row per thread with its size and unread count; flat shows all")
    func threadedAndFlatAreTwoQueriesOverTheSameRows() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(
            sentAt: [1_700_000_001, 1_700_000_002, 1_700_000_003],
            firstRemoteId: 1,
            threadRootId: "<root@example.invalid>",
            seenEvery: 3
        )
        try await mirror.addMessages(sentAt: [1_700_000_004], firstRemoteId: 4)
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 4 })
        #expect(model.rows.allSatisfy { $0.threadCount == 1 })

        model.show(.mailbox(mirror.mailboxId), view: .threaded)
        #expect(await waitUntil { model.rows.count == 2 })
        let thread = try #require(model.rows.first { $0.threadRootId != nil })
        #expect(thread.threadCount == 3)
        // Two of the three unread, and the newest of the three is the row on screen.
        #expect(thread.threadUnreadCount == 2)
        #expect(thread.sentAt == 1_700_000_003)
    }

    // MARK: - The window

    @Test("the window starts at the first screens and grows from zero")
    func theWindowGrowsFromZero() async throws {
        let mirror = try await MessageListMirror.seed()
        let total = MessageListStore.initialWindow + MessageListStore.windowStep + 5
        try await mirror.addMessages(sentAt: (1...total).map { 1_700_000_000 + Int64($0) })
        try await mirror.finishEnumerating()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == MessageListStore.initialWindow })
        #expect(model.hasMore)
        let newestBefore = try #require(model.rows.first).id

        model.loadMore()
        let grown = MessageListStore.initialWindow + MessageListStore.windowStep
        #expect(await waitUntil { model.rows.count == grown })
        // Anchored at zero, not paged: row zero is still row zero after the window grows.
        #expect(model.rows.first?.id == newestBefore)
        #expect(model.hasMore)

        model.loadMore()
        #expect(await waitUntil { model.rows.count == total })
        #expect(model.hasMore == false)
    }

    @Test("asking for more at the tail changes nothing")
    func loadMoreAtTheTailIsANoOp() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })

        model.loadMore()
        model.loadMore()
        #expect(await waitUntil { model.rows.count == 10 })
        #expect(model.hasMore == false)
    }

    // MARK: - One observation at a time

    @Test("changing mailbox replaces the observation rather than adding one")
    func theObservationIsReplaced() async throws {
        let mirror = try await Self.mirrorWithTen()
        let second = try await mirror.addMailbox(remoteId: 1006, name: "Archive")
        try await mirror.addMessages(sentAt: [1_800_000_001], firstRemoteId: 100, into: second)
        try await mirror.finishEnumerating(mailbox: second)
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })

        model.show(.mailbox(second), view: .flat)
        #expect(await waitUntil { model.rows.count == 1 })

        // A write to the mailbox that is no longer shown. If its observation were still
        // running it would deliver eleven rows over the top of this one.
        try await mirror.addMessages(sentAt: [1_700_000_099], firstRemoteId: 99)
        try await mirror.addMessages(sentAt: [1_800_000_002], firstRemoteId: 101, into: second)

        #expect(await waitUntil { model.rows.count == 2 })
        #expect(model.rows.allSatisfy { $0.mailboxId == second })
    }

    @Test("showing the same mailbox again does not restart anything")
    func showIsIdempotent() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        model.loadMore()

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        // The window was not reset, and the rows were not cleared and refetched.
        #expect(model.rows.count == 10)
        #expect(model.selection.isEmpty)
    }

    @Test("stopping ends the observation")
    func stopEndsTheObservation() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })

        model.stop()
        try await mirror.addMessages(sentAt: [1_700_000_099], firstRemoteId: 99)
        // Ten chances for a delivery that must not come.
        for _ in 0..<10 { await Task.yield() }
        #expect(model.rows.count == 10)
    }

    // MARK: - Selection

    @Test("a single selection is what the detail column shows; a multi-selection is not")
    func selectionPublishesCleanly() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })

        let newest = try #require(model.rows.first)
        let next = try #require(model.rows.dropFirst().first)

        model.selection = [newest.id]
        #expect(model.focusedMessageId == newest.id)
        #expect(model.selectedRows.map(\.id) == [newest.id])
        #expect(model.selectedRows.map(\.remoteId) == [newest.remoteId])

        model.selection = [newest.id, next.id]
        #expect(model.focusedMessageId == nil)
        #expect(Set(model.selectedRows.map(\.id)) == [newest.id, next.id])
        // Newest first, so a range action applies in the order the list shows.
        #expect(model.selectedRows.map(\.id) == [newest.id, next.id])
    }

    @Test("changing mailbox clears the selection")
    func selectionDoesNotSurviveAMailboxChange() async throws {
        let mirror = try await Self.mirrorWithTen()
        let second = try await mirror.addMailbox(remoteId: 1006, name: "Archive")
        let model = MessageListStore(store: mirror.store)
        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        model.selection = Set(model.rows.prefix(3).map(\.id))

        model.show(.mailbox(second), view: .flat)
        #expect(model.selection.isEmpty)
        #expect(model.focusedMessageId == nil)
    }

    // MARK: - States

    @Test("no mailbox selected")
    func noMailboxSelected() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.show(nil, view: .flat)
        #expect(model.presentation == .noMailboxSelected)
        #expect(model.rows.isEmpty)
    }

    @Test("an empty mailbox that is still enumerating says so, and one that has finished says no messages")
    func mirroringThenEmpty() async throws {
        let mirror = try await MessageListMirror.seed()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.presentation == .mirroring })
        #expect(model.isMirroring)

        try await mirror.finishEnumerating()
        #expect(await waitUntil { model.presentation == .emptyMailbox })
        #expect(model.isMirroring == false)
    }

    @Test("an empty mailbox with no route says it has not been downloaded")
    func notDownloadedOffline() async throws {
        let mirror = try await MessageListMirror.seed()
        let model = MessageListStore(store: mirror.store)
        model.isOffline = true

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.presentation == .notDownloaded })
    }

    @Test("airplane mode changes nothing about a mirrored mailbox")
    func offlineChangesNothingOnAMirroredMailbox() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        model.isOffline = true

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        #expect(model.presentation == .rows)

        model.loadMore()
        #expect(model.rows.count == 10)
    }

    @Test("a mailbox still filling shows the rows it has, never a downloading screen")
    func aPartlyFilledMailboxShowsItsRows() async throws {
        let mirror = try await MessageListMirror.seed()
        try await mirror.addMessages(sentAt: [1_700_000_001, 1_700_000_002])
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 2 })
        #expect(model.presentation == .rows)
        // The rows land before the mailbox row does — two observations, and the one the list
        // is for is started first. Which is the right way round: the mirror state decides
        // what to say when there are no rows, and there are rows.
        #expect(await waitUntil { model.mailbox != nil })
        #expect(model.isMirroring)
        #expect(model.presentation == .rows)
    }

    // MARK: - The filter WS-11 will build

    @Test("a filter with no query behind it shows no results, never the unfiltered mailbox")
    func aFilterWithoutASourceShowsNoResults() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat, filter: MessageListFilter(query: "risotto"))
        #expect(model.rows.isEmpty)
        #expect(model.presentation == .noResults("risotto"))
    }

    @Test("a filtered source replaces the query the window is opened on")
    func aFilteredSourceTakesOver() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)
        let store = mirror.store
        let mailboxId = mirror.mailboxId
        // Stands in for WS-11's search observation: same rows, a narrower window.
        model.filteredSource = { range in
            store.observeMessages(mailboxId: mailboxId, view: .flat, range: 0..<min(range.upperBound, 3))
        }

        model.show(.mailbox(mailboxId), view: .flat, filter: MessageListFilter(query: "redacted"))
        #expect(await waitUntil { model.rows.count == 3 })
        #expect(model.presentation == .rows)

        model.show(.mailbox(mailboxId), view: .flat, filter: nil)
        #expect(await waitUntil { model.rows.count == 10 })
    }

    // MARK: - Sections

    @Test("rows and sections are assigned together")
    func sectionsFollowTheRows() async throws {
        let mirror = try await Self.mirrorWithTen()
        let model = MessageListStore(store: mirror.store)

        model.show(.mailbox(mirror.mailboxId), view: .flat)
        #expect(await waitUntil { model.rows.count == 10 })
        #expect(model.sections.reduce(0) { $0 + $1.rows.count } == model.rows.count)
        // 2023-11-14 by anybody's calendar, so one bucket holds all ten.
        #expect(model.sections.count == 1)
        #expect(model.sections.first?.dateGroup == .year(2023))

        model.show(nil, view: .flat)
        #expect(model.sections.isEmpty)
    }
}
