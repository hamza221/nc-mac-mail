// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NCMailCore

/// `MailboxTree.layout(accounts:outboxCount:)` and the folder-name helpers: the §3.1 rules of
/// the web client's navigation (virtual entries, Favorites, folder collapse, Outbox), pure.
@Suite("SidebarLayout")
struct SidebarLayoutTests {
    private func row(
        id: Int64,
        name: String,
        delimiter: String? = "/",
        specialRole: String? = nil,
        isSubscribed: Bool = true,
        unreadCount: Int = 0,
        remoteId: Int64? = nil,
        rights: String? = nil
    ) -> MailboxTreeRow {
        MailboxTreeRow(
            id: id,
            name: name,
            delimiter: delimiter,
            specialRole: specialRole,
            isSelectable: true,
            isSubscribed: isSubscribed,
            unreadCount: unreadCount,
            remoteId: remoteId ?? id,
            rights: rights
        )
    }

    private var standardRows: [MailboxTreeRow] {
        [
            row(id: 1, name: "INBOX", specialRole: "inbox", unreadCount: 3),
            row(id: 2, name: "Drafts", specialRole: "drafts"),
            row(id: 3, name: "Sent", specialRole: "sent"),
            row(id: 4, name: "Trash", specialRole: "trash"),
            row(id: 5, name: "Archive", specialRole: "archive"),
            row(id: 6, name: "Projects"),
        ]
    }

    private func mailboxNames(_ items: [SidebarItem]) -> [String] {
        items.compactMap { item in
            if case .mailbox(let node) = item { return node.displayName }
            return nil
        }
    }

    // MARK: - Virtual entries

    @Test("one account: Priority inbox only, no All inboxes")
    func oneAccountHasNoUnifiedInbox() {
        let layout = MailboxTree.layout(
            accounts: [SidebarAccountInput(accountId: 1, rows: standardRows)], outboxCount: 0)
        #expect(layout.virtualEntries == [.priorityInbox])
    }

    @Test("two accounts: All inboxes appears, counting both inboxes' unread")
    func twoAccountsAddUnifiedInbox() {
        let second = [row(id: 11, name: "INBOX", specialRole: "inbox", unreadCount: 4)]
        let layout = MailboxTree.layout(
            accounts: [
                SidebarAccountInput(accountId: 1, rows: standardRows),
                SidebarAccountInput(accountId: 2, rows: second),
            ],
            outboxCount: 0
        )
        #expect(layout.virtualEntries == [.priorityInbox, .unifiedInbox(unreadCount: 7)])
    }

    @Test("the Outbox entry exists only while the outbox has messages")
    func outboxVisibility() {
        let input = [SidebarAccountInput(accountId: 1, rows: standardRows)]
        #expect(MailboxTree.layout(accounts: input, outboxCount: 0).outboxCount == nil)
        #expect(MailboxTree.layout(accounts: input, outboxCount: 2).outboxCount == 2)
    }

    // MARK: - Favorites

    @Test("Favorites follows the Inbox, carrying the Inbox's id")
    func favoritesFollowsInbox() throws {
        let layout = MailboxTree.layout(
            accounts: [SidebarAccountInput(accountId: 1, rows: standardRows, showsAllFolders: true)],
            outboxCount: 0
        )
        let items = try #require(layout.accounts.first).items
        #expect(items[1] == .favorites(inboxId: 1))
        guard case .mailbox(let first) = items[0] else {
            Issue.record("the first item is not the Inbox")
            return
        }
        #expect(first.row?.id == 1)
    }

    @Test("a subfolder named like an inbox gets no Favorites entry; only a top-level Inbox does")
    func favoritesOnlyForTopLevelInbox() throws {
        let rows = [
            row(id: 1, name: "INBOX", specialRole: "inbox"),
            row(id: 2, name: "INBOX/Sub", specialRole: nil),
        ]
        let items = try #require(
            MailboxTree.layout(accounts: [SidebarAccountInput(accountId: 1, rows: rows)], outboxCount: 0)
                .accounts.first
        ).items
        #expect(items.filter { if case .favorites = $0 { true } else { false } }.count == 1)
    }

    // MARK: - Collapse

    @Test("collapsed by default: Inbox, Drafts, Sent, Trash shown, the rest behind the toggle")
    func collapsedShowsPinnedOnly() throws {
        let items = try #require(
            MailboxTree.layout(accounts: [SidebarAccountInput(accountId: 1, rows: standardRows)], outboxCount: 0)
                .accounts.first
        ).items
        #expect(mailboxNames(items) == ["INBOX", "Drafts", "Sent", "Trash"])
        #expect(items.last == .folderToggle(expanded: false))
    }

    @Test("show all folders lists everything, with Collapse folders last")
    func expandedShowsAll() throws {
        let items = try #require(
            MailboxTree.layout(
                accounts: [SidebarAccountInput(accountId: 1, rows: standardRows, showsAllFolders: true)],
                outboxCount: 0
            ).accounts.first
        ).items
        #expect(mailboxNames(items) == ["INBOX", "Drafts", "Sent", "Archive", "Trash", "Projects"])
        #expect(items.last == .folderToggle(expanded: true))
    }

    @Test("one other folder is not collapsible: no toggle, everything shown")
    func singleOtherFolderIsNotCollapsible() throws {
        let rows = Array(standardRows.prefix(5))
        let items = try #require(
            MailboxTree.layout(accounts: [SidebarAccountInput(accountId: 1, rows: rows)], outboxCount: 0)
                .accounts.first
        ).items
        #expect(mailboxNames(items) == ["INBOX", "Drafts", "Sent", "Archive", "Trash"])
        #expect(!items.contains(.folderToggle(expanded: false)))
    }

    @Test("the account's configured special folders are pinned even without a role")
    func configuredIdsArePinned() throws {
        let rows = [
            row(id: 1, name: "INBOX", specialRole: "inbox"),
            row(id: 2, name: "Entwürfe", remoteId: 20),
            row(id: 3, name: "A"),
            row(id: 4, name: "B"),
        ]
        let items = try #require(
            MailboxTree.layout(
                accounts: [SidebarAccountInput(accountId: 1, rows: rows, pinnedRemoteIds: [20])], outboxCount: 0
            ).accounts.first
        ).items
        #expect(mailboxNames(items) == ["INBOX", "Entwürfe"])
    }

    // MARK: - Subscribed only, disabled

    @Test("show only subscribed folders drops unsubscribed rows")
    func subscribedOnlyFilters() throws {
        let rows = standardRows + [row(id: 7, name: "Old", isSubscribed: false)]
        let layout = try #require(
            MailboxTree.layout(
                accounts: [
                    SidebarAccountInput(accountId: 1, rows: rows, showSubscribedOnly: true, showsAllFolders: true)
                ],
                outboxCount: 0
            ).accounts.first
        )
        #expect(!mailboxNames(layout.items).contains("Old"))
        #expect(!layout.tree.contains { $0.displayName == "Old" })
    }

    @Test("a disabled account has no rows")
    func disabledAccountIsEmpty() throws {
        let layout = try #require(
            MailboxTree.layout(
                accounts: [SidebarAccountInput(accountId: 1, rows: standardRows, isDisabled: true)], outboxCount: 0
            ).accounts.first
        )
        #expect(layout.items.isEmpty)
    }

    // MARK: - Counts and rights

    @Test("a parent's second count is its subfolders' unread, all levels down")
    func descendantUnread() throws {
        let rows = [
            row(id: 1, name: "Work", unreadCount: 1),
            row(id: 2, name: "Work/A", unreadCount: 2),
            row(id: 3, name: "Work/A/B", unreadCount: 5),
        ]
        let work = try #require(MailboxTree.build(from: rows).first)
        #expect(work.unreadCount == 1)
        #expect(work.descendantUnreadCount == 7)
    }

    @Test("rights: nil allows everything; otherwise every letter must be held")
    func rights() {
        #expect(row(id: 1, name: "A").allows("kx"))
        #expect(row(id: 1, name: "A", rights: "lrsk").allows("k"))
        #expect(!row(id: 1, name: "A", rights: "lrsk").allows("kx"))
        #expect(!row(id: 1, name: "A", rights: "lr").allows("te"))
    }

    // MARK: - Names

    @Test("a folder name is trimmed, and refused when empty or containing the delimiter")
    func validatedLeaf() {
        #expect(MailboxTree.validatedLeaf("  Work ", delimiter: "/") == "Work")
        #expect(MailboxTree.validatedLeaf("   ", delimiter: "/") == nil)
        #expect(MailboxTree.validatedLeaf("A/B", delimiter: "/") == nil)
        #expect(MailboxTree.validatedLeaf("A/B", delimiter: nil) == "A/B")
    }

    @Test("a subfolder joins its parent's path; a rename keeps the parent")
    func childAndRenamedNames() {
        let parent = row(id: 1, name: "Work/Clients")
        #expect(MailboxTree.childName(of: parent, leaf: "Acme") == "Work/Clients/Acme")
        #expect(MailboxTree.childName(of: nil, leaf: "Acme") == "Acme")
        #expect(MailboxTree.renamedName(of: parent, to: "Customers") == "Work/Customers")
        #expect(MailboxTree.renamedName(of: row(id: 2, name: "Top"), to: "Renamed") == "Renamed")
    }

    @Test("move targets exclude the folder, its subfolders and folders without right k")
    func moveTargets() {
        let moving = row(id: 1, name: "Work")
        let rows = [
            moving,
            row(id: 2, name: "Work/Child"),
            row(id: 3, name: "Personal"),
            row(id: 4, name: "Shared", rights: "lr"),
            row(id: 5, name: "Workshop"),
        ]
        #expect(MailboxTree.moveTargets(for: moving, in: rows).map(\.id) == [3, 5])
    }
}
