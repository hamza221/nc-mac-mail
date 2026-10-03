// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import Testing

@testable import NextcloudMail

/// `SidebarStore` against a real, migrated, in-memory mirror -- no fake transport, because
/// nothing here ever reaches `NCMailNet`. Every assertion that depends on an async observation
/// landing polls with `Task.yield()` rather than sleeping, matching
/// `NavigationStateTests.settled(_:_:is:)`: a value that never arrives fails as a wrong value
/// instead of a hang, and the suite never depends on the wall clock (definition-of-done.md).
@MainActor
@Suite("SidebarStore")
struct SidebarStoreTests {
    // MARK: - Seeding

    @discardableResult
    private func makeAccount(
        _ store: MailStore,
        loginName: String = "lorelai",
        serverURL: String = "https://cloud.example.com",
        remoteId: Int64 = 1,
        name: String = "Work",
        sortOrder: Int = 0
    ) async throws -> AccountRecord {
        let write = AccountWrite(
            identity: ServerIdentity(serverURL: serverURL, loginName: loginName),
            remoteId: remoteId,
            name: name,
            emailAddress: "lorelai@dragonfly.example",
            sortOrder: sortOrder
        )
        let records = try await store.upsert(accounts: [write])
        return try #require(records.first)
    }

    @discardableResult
    private func makeMailbox(
        _ store: MailStore,
        accountId: Int64,
        remoteId: Int64,
        name: String,
        delimiter: String? = "/",
        specialRole: String? = nil,
        isSubscribed: Bool = true,
        isSelectable: Bool = true,
        unreadCount: Int = 0
    ) async throws -> MailboxRecord {
        let write = MailboxWrite(
            accountId: accountId,
            remoteId: remoteId,
            name: name,
            delimiter: delimiter,
            displayName: name,
            specialRole: specialRole,
            isSubscribed: isSubscribed,
            isSelectable: isSelectable,
            unreadCount: unreadCount
        )
        let records = try await store.upsert(mailboxes: [write], accountId: accountId)
        return try #require(records.first)
    }

    /// Polls a `SidebarStore` property until it matches, rather than sleeping: every mutation
    /// here lands through a detached `Task`, so a read issued right after starting an
    /// observation can beat the write.
    private func settled<T: Equatable>(_ read: () -> T, is expected: T, attempts: Int = 2000) async -> Bool {
        for _ in 0..<attempts {
            if read() == expected { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - Tests

    @Test("an empty mirror shows no accounts and no trees")
    func emptyMirrorShowsNothing() async throws {
        let store = try MailStore.inMemory()
        let model = SidebarStore(store: store)
        model.start()
        #expect(await settled({ model.accounts.isEmpty }, is: true))
        #expect(model.mailboxNodes.isEmpty)
    }

    @Test("one account's mailboxes build into its tree, in the right order")
    func oneAccountBuildsItsTree() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        try await makeMailbox(store, accountId: account.id, remoteId: 2, name: "Work/Projects")

        let model = SidebarStore(store: store)
        model.start()
        #expect(await settled({ model.accounts.count }, is: 1))
        #expect(await settled({ model.mailboxNodes[account.id]?.count }, is: 2))

        let nodes = try #require(model.mailboxNodes[account.id])
        #expect(nodes.map(\.displayName) == ["INBOX", "Work"])
        let work = try #require(nodes.first { $0.displayName == "Work" })
        #expect(work.row == nil, "Work is synthetic: only Work/Projects was ever a row")
        #expect(work.children.map(\.displayName) == ["Projects"])
    }

    @Test("two accounts keep independent trees")
    func twoAccountsHaveIndependentTrees() async throws {
        let store = try MailStore.inMemory()
        let work = try await makeAccount(store, loginName: "lorelai", remoteId: 1, name: "Work", sortOrder: 0)
        let personal = try await makeAccount(
            store,
            loginName: "lorelai-personal",
            remoteId: 1,
            name: "Personal",
            sortOrder: 1
        )
        try await makeMailbox(store, accountId: work.id, remoteId: 1, name: "INBOX", specialRole: "inbox")
        try await makeMailbox(store, accountId: personal.id, remoteId: 1, name: "INBOX", specialRole: "inbox")

        let model = SidebarStore(store: store)
        model.start()
        #expect(await settled({ model.accounts.count }, is: 2))
        #expect(await settled({ model.mailboxNodes[work.id]?.count }, is: 1))
        #expect(await settled({ model.mailboxNodes[personal.id]?.count }, is: 1))

        // Same server-numbered remoteId (1) on both accounts; the local ids stay distinct,
        // which is the whole of ADR-0033 and this story's (S-10) reason to exist.
        let workInbox = try #require(model.mailboxNodes[work.id]?.first)
        let personalInbox = try #require(model.mailboxNodes[personal.id]?.first)
        #expect(workInbox.row?.id != personalInbox.row?.id)
    }

    @Test("an unread count arriving later updates the tree live")
    func unreadCountUpdatesLive() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")

        let model = SidebarStore(store: store)
        model.start()
        #expect(await settled({ model.mailboxNodes[account.id]?.first?.unreadCount }, is: 0))

        try await makeMailbox(
            store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox", unreadCount: 7
        )
        #expect(await settled({ model.mailboxNodes[account.id]?.first?.unreadCount }, is: 7))
    }

    @Test("removing an account clears its tree")
    func removingAnAccountClearsItsTree() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        try await makeMailbox(store, accountId: account.id, remoteId: 1, name: "INBOX", specialRole: "inbox")

        let model = SidebarStore(store: store)
        model.start()
        #expect(await settled({ model.mailboxNodes[account.id]?.count }, is: 1))

        try await store.deleteAccount(id: account.id)
        #expect(await settled({ model.accounts.isEmpty }, is: true))
        #expect(model.mailboxNodes[account.id] == nil)
    }

    @Test("a node with no persisted state is expanded by default")
    func expansionDefaultsToExpanded() throws {
        let model = SidebarStore(store: try MailStore.inMemory())
        let node = MailboxNode(
            row: MailboxTreeRow(
                id: 1, name: "INBOX", delimiter: "/", specialRole: "inbox", isSelectable: true, isSubscribed: true,
                unreadCount: 0
            ),
            children: [],
            depth: 0,
            path: ["INBOX"]
        )
        #expect(model.isExpanded(accountId: 1, node: node) == true)
    }

    @Test("collapsing a node persists, and a fresh store started against the same mirror reads it back")
    func expansionRoundTrips() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let node = MailboxNode(
            row: MailboxTreeRow(
                id: 1, name: "Work", delimiter: "/", specialRole: nil, isSelectable: false, isSubscribed: true,
                unreadCount: 0
            ),
            children: [],
            depth: 0,
            path: ["Work"]
        )

        let first = SidebarStore(store: store)
        first.start()
        #expect(await settled({ first.accounts.count }, is: 1))
        first.setExpanded(false, accountId: account.id, node: node)
        #expect(await settled({ first.isExpanded(accountId: account.id, node: node) }, is: false))

        let second = SidebarStore(store: store)
        second.start()
        #expect(await settled({ second.accounts.count }, is: 1))
        #expect(await settled({ second.isExpanded(accountId: account.id, node: node) }, is: false))
    }
}
