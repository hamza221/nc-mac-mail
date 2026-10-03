// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// Restoration, both directions: what a setter writes to `meta`, and what `load()` makes of
/// what it finds there — including values it cannot use.
///
/// The three key names are spelled out rather than read from `NavigationState.MetaKey`, which
/// is private. That is deliberate: WS-07 and WS-08 will write the same rows from the sidebar
/// and the message list, so the names are a contract between workstreams and a rename should
/// fail here.
@Suite("NavigationState persistence")
struct NavigationStateTests {
    private static let mailboxKey = "navigation.selectedMailboxId"
    private static let listViewKey = "navigation.listView"

    @Test("an empty mirror restores the defaults")
    func emptyStoreLeavesDefaults() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selectedMailboxID == nil)
        #expect(navigation.listView == .threaded)
    }

    @Test("a selection survives into the next launch")
    func selectionsRoundTrip() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)

        navigation.selectMailbox(42)
        navigation.setListView(.flat)

        #expect(navigation.selectedMailboxID == 42)
        #expect(navigation.listView == .flat)

        #expect(try await settled(store, Self.mailboxKey, is: "42"))
        #expect(try await settled(store, Self.listViewKey, is: "flat"))

        let relaunched = NavigationState(store: store)
        await relaunched.load()
        #expect(relaunched.selectedMailboxID == 42)
        #expect(relaunched.listView == .flat)
    }

    @Test("clearing a selection deletes the row rather than writing an empty one")
    func nilSelectionRemovesTheKey() async throws {
        let store = try MailStore.inMemory()
        let navigation = NavigationState(store: store)

        navigation.selectMailbox(42)
        #expect(try await settled(store, Self.mailboxKey, is: "42"))

        navigation.selectMailbox(nil)
        #expect(navigation.selectedMailboxID == nil)
        #expect(try await settled(store, Self.mailboxKey, is: nil))
    }

    @Test("a mailbox id that is not a number loads as no selection")
    func unparsableMailboxIdIsIgnored() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("inbox", forKey: Self.mailboxKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selectedMailboxID == nil)
    }

    @Test("a list view this version does not know keeps the default")
    func unknownListViewKeepsTheDefault() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("mosaic", forKey: Self.listViewKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.listView == .threaded)
    }

    @Test("each key is read independently of the others")
    func aMissingKeyDoesNotBlockTheRest() async throws {
        let store = try MailStore.inMemory()
        try await store.setMetaValue("flat", forKey: Self.listViewKey)

        let navigation = NavigationState(store: store)
        await navigation.load()
        #expect(navigation.selectedMailboxID == nil)
        #expect(navigation.listView == .flat)
    }

    /// `NavigationState`'s setters persist in a detached `Task`, so a read issued straight
    /// after one can beat the write to the queue. Yielding rather than sleeping keeps the
    /// suite off the wall clock; a value that never arrives fails as a wrong value, not a hang.
    private func settled(_ store: MailStore, _ key: String, is expected: String?) async throws -> Bool {
        for _ in 0..<1000 {
            if try await store.metaValue(forKey: key) == expected { return true }
            await Task.yield()
        }
        return false
    }
}
