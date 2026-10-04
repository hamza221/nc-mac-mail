// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// Restoration, both directions: what a setter writes to `meta`, and what `load()` makes of
/// what it finds there — including values it cannot use — plus the start-mailbox settle.
///
/// The key names are spelled out rather than read from `NavigationState.MetaKey`, which is
/// private: they are what an older mirror holds, so a rename should fail here.
@Suite("NavigationState persistence")
struct NavigationStateTests {
    private static let selectionKey = "navigation.selection"
    private static let legacyMailboxKey = "navigation.selectedMailboxId"
    private static let listViewKey = "navigation.listView"

    @Test("an empty mirror restores the defaults")
    func emptyStoreLeavesDefaults() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selection == nil)
        #expect(navigation.selectedMailboxID == nil)
        #expect(navigation.listView == .threaded)
    }

    @Test(
        "every kind of selection survives into the next launch",
        arguments: [
            SidebarSelection.mailbox(42), .unifiedInbox, .priorityInbox, .favorites(inboxId: 7), .outbox,
            .contacts(sessionId: "https://cloud.example.com#alice", scope: .all),
            .contacts(sessionId: "s", scope: .favorites),
            .contacts(sessionId: "s", scope: .addressBook(3)),
            .contacts(sessionId: "s", scope: .group("Family")),
            .contacts(sessionId: "s", scope: .team("circle-1")),
            .contacts(sessionId: "s", scope: .recent),
        ]
    )
    func selectionRoundTrips(selection: SidebarSelection) async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)

        navigation.select(selection)
        #expect(navigation.selection == selection)
        #expect(try await settled(store, Self.selectionKey) { $0 != nil })

        let relaunched = NavigationState(store: store)
        await relaunched.load()
        #expect(relaunched.selection == selection)
        #expect(relaunched.selectedMailboxID == selection.mailboxId)
    }

    @Test("the list view survives into the next launch")
    func listViewRoundTrips() async throws {
        let store = try MailStore.inMemory()
        NavigationState(store: store).setListView(.flat)
        #expect(try await settled(store, Self.listViewKey) { $0 == "flat" })

        let relaunched = NavigationState(store: store)
        await relaunched.load()
        #expect(relaunched.listView == .flat)
    }

    @Test("clearing a selection deletes the row rather than writing an empty one")
    func nilSelectionRemovesTheKey() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)

        navigation.selectMailbox(42)
        #expect(try await settled(store, Self.selectionKey) { $0 != nil })

        navigation.selectMailbox(nil)
        #expect(navigation.selection == nil)
        #expect(try await settled(store, Self.selectionKey) { $0 == nil })
    }

    @Test("v1's saved mailbox becomes the selection once, under the new key")
    func legacyMailboxMigrates() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("42", forKey: Self.legacyMailboxKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selection == .mailbox(42))
        #expect(try await store.metaValue(forKey: Self.legacyMailboxKey) == nil)
        #expect(try await settled(store, Self.selectionKey) { $0 != nil })

        let relaunched = NavigationState(store: store)
        await relaunched.load()
        #expect(relaunched.selection == .mailbox(42))
    }

    @Test("a selection this version cannot read loads as no selection")
    func unreadableSelectionIsIgnored() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue(#"{"calendar":{}}"#, forKey: Self.selectionKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selection == nil)
    }

    @Test("a list view this version does not know keeps the default")
    func unknownListViewKeepsTheDefault() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("mosaic", forKey: Self.listViewKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.listView == .threaded)
    }

    // MARK: - The server's start mailbox

    @Test("with nothing saved locally, the launch opens on the server's start mailbox")
    func startMailboxIsTheFallback() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)
        navigation.startMailbox = { .unifiedInbox }
        var heard: [Int64?] = []
        navigation.mailboxDidChange = { heard.append($0) }

        await navigation.load()
        #expect(navigation.selection == .unifiedInbox)
        #expect(heard == [nil])
    }

    @Test("a selection saved on this Mac wins over the server's start mailbox")
    func localSelectionWins() async throws {
        let store = try MailStore.inMemory()
        NavigationState(store: store).select(.outbox)
        #expect(try await settled(store, Self.selectionKey) { $0 != nil })

        let navigation = NavigationState(store: store)
        var asked = false
        navigation.startMailbox = {
            asked = true
            return .unifiedInbox
        }
        await navigation.load()
        #expect(navigation.selection == .outbox)
        #expect(asked == false)
    }

    @Test("only a selection that stood for the settle delay becomes the start mailbox")
    func settleSavesOnlyTheLastCandidate() async throws {
        let gate = Gate()
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store, sleep: { _ in await gate.wait() })
        var saved: [SidebarSelection] = []
        navigation.startMailboxDidSettle = { saved.append($0) }

        navigation.select(.mailbox(1))
        navigation.select(.mailbox(2))
        navigation.select(.priorityInbox)
        await gate.open()

        for _ in 0..<1000 where saved.isEmpty { await Task.yield() }
        #expect(saved == [.priorityInbox])
    }

    @Test("favorites, the outbox and contacts are never a start mailbox")
    func nonCandidatesNeverSettle() async throws {
        let gate = Gate()
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store, sleep: { _ in await gate.wait() })
        var saved: [SidebarSelection] = []
        navigation.startMailboxDidSettle = { saved.append($0) }

        navigation.select(.favorites(inboxId: 1))
        navigation.select(.outbox)
        navigation.select(.contacts(sessionId: "s", scope: .all))
        await gate.open()
        for _ in 0..<200 { await Task.yield() }
        #expect(saved.isEmpty)
    }

    /// The setters persist in a detached `Task`, so a read issued straight after one can
    /// beat the write. Yielding rather than sleeping keeps the suite off the wall clock; a
    /// value that never arrives fails as a wrong value, not a hang.
    private func settled(_ store: MailStore, _ key: String, _ matches: (String?) -> Bool) async throws -> Bool {
        for _ in 0..<1000 {
            if matches(try await store.metaValue(forKey: key)) { return true }
            await Task.yield()
        }
        return false
    }
}

/// A sleep the test ends: every waiter resumes when the gate opens.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
