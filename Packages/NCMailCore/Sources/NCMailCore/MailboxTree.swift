// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// The columns `MailboxTree` needs from one mailbox row, independent of where the row came
/// from.
///
/// This is not `Mailbox` (`Models/Mailbox.swift`), on purpose. `Mailbox.id` decodes the
/// server's `databaseId`, which is exactly the "a mailbox 5" problem
/// [ADR-0033](../../../../docs/decisions/0033-accounts-have-a-local-identity.md) exists to
/// stop: two servers can hand out the same number, and the sidebar's selection has to stay
/// unique across every account it draws. The sidebar's real input is
/// `NCMailStore.MailboxRecord`, whose `id` is the mirror's own — but `NCMailCore` must not
/// import `NCMailStore` (dependencies point downward only, see
/// [overview.md](../../../../docs/architecture/overview.md#modules)), so this file cannot
/// name that type either. `MailboxTreeRow` is the small, dependency-free shape both sides can
/// agree on: `NextcloudMail/Views/Sidebar` builds one per `MailboxRecord` with a plain
/// memberwise conversion — no JSON, no GRDB, nothing the app target is not already allowed to
/// touch. See [ADR-0046](../../../../docs/decisions/0046-mailboxtree-takes-its-own-row-type.md).
public struct MailboxTreeRow: Sendable, Hashable, Identifiable {
    /// The mirror's local id. Never the server's — see the type's own doc comment.
    public let id: Int64
    /// The full IMAP path, delimiter and all, e.g. `INBOX.Work.Archive`.
    public let name: String
    /// `nil` or empty means a flat namespace: `name` is never split.
    public let delimiter: String?
    /// `nil` where the server sent the integer `0`. Left as a string so an unmodelled role
    /// round-trips instead of failing to build a tree.
    public let specialRole: String?
    public let isSelectable: Bool
    public let isSubscribed: Bool
    public let unreadCount: Int
    /// The last sync of this mailbox failed. The row only says so on hover; Get info explains
    /// ([ux-spec.md](../../../../docs/product/ux-spec.md#errors-and-the-rule-about-them)).
    public let hasSyncFailure: Bool
    /// The server's `databaseId`. Only ever compared with the account's own server-numbered
    /// special-folder ids (`account.draftsMailboxId` and siblings), never used as identity.
    public let remoteId: Int64?
    /// The server's total as of the last folder refresh; nil before the first one.
    public let totalCount: Int?
    public let syncInBackground: Bool
    /// The server's IMAP ACL rights for the signed-in user (`myAcls`, e.g. `"lrswipkxtea"`).
    /// Nil when the server has no ACL support, which allows everything.
    public let rights: String?
    /// Another user's folder shared into this account.
    public let isShared: Bool

    public init(
        id: Int64,
        name: String,
        delimiter: String?,
        specialRole: String?,
        isSelectable: Bool,
        isSubscribed: Bool,
        unreadCount: Int,
        hasSyncFailure: Bool = false,
        remoteId: Int64? = nil,
        totalCount: Int? = nil,
        syncInBackground: Bool = false,
        rights: String? = nil,
        isShared: Bool = false
    ) {
        self.id = id
        self.name = name
        self.delimiter = delimiter
        self.specialRole = specialRole
        self.isSelectable = isSelectable
        self.isSubscribed = isSubscribed
        self.unreadCount = unreadCount
        self.hasSyncFailure = hasSyncFailure
        self.remoteId = remoteId
        self.totalCount = totalCount
        self.syncInBackground = syncInBackground
        self.rights = rights
        self.isShared = isShared
    }

    /// Whether the user holds every right in `required`, one ACL letter each (RFC 4314: `k`
    /// create, `x` delete mailbox, `t` delete messages, `e` expunge, `s` seen, `i` insert).
    /// Matches the web client's `mailboxHasRights`: no ACL support means no restriction.
    public func allows(_ required: String) -> Bool {
        guard let rights else { return true }
        return required.allSatisfy(rights.contains)
    }

    /// `name`, split on the row's own delimiter -- the same split the tree uses.
    public var pathComponents: [String] {
        guard let delimiter, !delimiter.isEmpty else { return [name] }
        return name.components(separatedBy: delimiter)
    }

    public var hasDelimiter: Bool { !(delimiter ?? "").isEmpty }
}

/// One row of the sidebar's tree, real or synthetic.
///
/// `row` is `nil` exactly when this node is a container `MailboxTree.build(from:)` invented
/// because a child's parent path had no row of its own — there is no mailbox to select, no
/// unread count to show, and no id to build a request from. A synthetic node is never
/// selectable, matching a real `\noselect` row, which is why callers can treat the two the
/// same way in the view: check ``isSelectable``, not whether ``row`` is nil.
public struct MailboxNode: Sendable, Hashable, Identifiable {
    public let row: MailboxTreeRow?
    public let children: [MailboxNode]
    public let depth: Int

    /// This node's full path, split on its own delimiter (or the whole name, for a flat
    /// namespace). Stable across rebuilds, and the only thing a synthetic node can use for
    /// identity: it has no ``row`` and so no numeric id.
    ///
    /// Joined with `\u{1F}` (ASCII unit separator) rather than the original delimiter, which a
    /// mailbox name is free to contain as ordinary text (`"A/B"` and `["A", "B"]` must not
    /// collide with a literal mailbox named `"A/B"` at the top level).
    public let path: [String]

    public var id: String { path.joined(separator: "\u{1F}") }

    /// The last path component -- what the row shows. Equal to `row.leafName` for a real row,
    /// and the synthetic container's own path component when there is none.
    public var displayName: String { path.last ?? "" }

    public var isSelectable: Bool { row?.isSelectable ?? false }
    public var isSubscribed: Bool { row?.isSubscribed ?? true }
    public var unreadCount: Int { row?.unreadCount ?? 0 }

    /// Unread messages in every folder below this one, not counting its own: the web
    /// client's "3 (5)" second figure.
    public var descendantUnreadCount: Int {
        children.reduce(0) { $0 + $1.unreadCount + $1.descendantUnreadCount }
    }

    /// This node and everything below it, depth first.
    public var subtree: [MailboxNode] {
        [self] + children.flatMap(\.subtree)
    }

    public init(row: MailboxTreeRow?, children: [MailboxNode], depth: Int, path: [String]) {
        self.row = row
        self.children = children
        self.depth = depth
        self.path = path
    }
}

/// Builds the sidebar's mailbox tree out of one account's flat rows.
///
/// Pure and synchronous. No I/O, no database, nothing that needs a `Task` -- which is what
/// makes every rule below a `MailboxTreeTests` case rather than something only a running app
/// can check ([ADR-0023](../../../../docs/decisions/0023-store-records-are-not-wire-models.md)
/// already made the store answer with rows for exactly this reason).
public enum MailboxTree {
    /// - Splits each row's `name` on its own `delimiter`; the display name is the last
    ///   component, because the server's `displayName` is the full path.
    /// - Orders siblings: inbox, drafts, sent, archive, junk, trash, then the rest
    ///   alphabetically, case- and locale-insensitive.
    /// - A child whose parent path has no row of its own gets a synthetic container node:
    ///   `isSelectable` false, `unreadCount` zero, no id to act on.
    /// - `\noselect` rows are real rows with `isSelectable == false`; they become container
    ///   nodes the same way a synthetic parent does, and are never confused with one because
    ///   the view checks `isSelectable`, not `row == nil`.
    /// - A `nil` or empty `delimiter` is a flat namespace: that row's `name` is never split,
    ///   so it is always a top-level node with no children of its own.
    public static func build(from rows: [MailboxTreeRow]) -> [MailboxNode] {
        guard !rows.isEmpty else { return [] }

        var rowsByPath: [[String]: MailboxTreeRow] = [:]
        for row in rows {
            rowsByPath[row.pathComponents] = row
        }

        // Every path that has to exist in the tree: each row's own path, and every ancestor
        // of it -- an ancestor with no row becomes a synthetic container.
        var neededPaths: Set<[String]> = []
        for path in rowsByPath.keys {
            var prefix = path
            while !prefix.isEmpty {
                neededPaths.insert(prefix)
                prefix.removeLast()
            }
        }

        func children(of parent: [String]) -> [MailboxNode] {
            let childPaths = neededPaths.filter {
                $0.count == parent.count + 1 && Array($0.prefix(parent.count)) == parent
            }
            return order(childPaths.map { makeNode(path: $0, depth: parent.count) })
        }

        func makeNode(path: [String], depth: Int) -> MailboxNode {
            MailboxNode(row: rowsByPath[path], children: children(of: path), depth: depth, path: path)
        }

        let topLevelPaths = neededPaths.filter { $0.count == 1 }
        return order(topLevelPaths.map { makeNode(path: $0, depth: 0) })
    }

    private static func order(_ nodes: [MailboxNode]) -> [MailboxNode] {
        nodes.sorted { lhs, rhs in
            let leftRank = rank(lhs)
            let rightRank = rank(rhs)
            guard leftRank == rightRank else { return leftRank < rightRank }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Inbox, drafts, sent, archive, junk, trash, in that order; everything else -- including
    /// a synthetic container -- sorts after all six by returning a rank past the table's end.
    private static let specialRoleRank: [String: Int] = [
        "inbox": 0, "drafts": 1, "sent": 2, "archive": 3, "junk": 4, "trash": 5,
    ]

    private static func rank(_ node: MailboxNode) -> Int {
        guard let role = node.row?.specialRole?.lowercased() else { return .max }
        return specialRoleRank[role] ?? .max
    }
}

// MARK: - Folder names

extension MailboxTree {
    /// The leaf a user typed, trimmed, or nil when the server would refuse it: empty, or
    /// containing the account's hierarchy delimiter (which would silently create a parent the
    /// user never asked for). The web client only learns this from the server's error; a
    /// queued create has no one to tell hours later, so it is refused here.
    public static func validatedLeaf(_ input: String, delimiter: String?) -> String? {
        let leaf = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty else { return nil }
        if let delimiter, !delimiter.isEmpty, leaf.contains(delimiter) { return nil }
        return leaf
    }

    /// The full path of a new folder `leaf` under `parent`, or at the top level for nil.
    public static func childName(of parent: MailboxTreeRow?, leaf: String) -> String {
        guard let parent, let delimiter = parent.delimiter, !delimiter.isEmpty else { return leaf }
        return parent.name + delimiter + leaf
    }

    /// `row`'s full path with its last component replaced: a rename stays where it is.
    public static func renamedName(of row: MailboxTreeRow, to leaf: String) -> String {
        guard let delimiter = row.delimiter, !delimiter.isEmpty else { return leaf }
        var components = row.pathComponents
        components[components.count - 1] = leaf
        return components.joined(separator: delimiter)
    }

    /// Where "Move folder" may put `row`: every folder the user may create children in
    /// (right `k`) that has a delimiter, except `row` itself and anything below it. The top
    /// level is always allowed and is not in this list -- the picker draws it as "/".
    public static func moveTargets(for row: MailboxTreeRow, in rows: [MailboxTreeRow]) -> [MailboxTreeRow] {
        let ownPath = row.pathComponents
        return rows.filter { candidate in
            guard candidate.id != row.id, candidate.hasDelimiter, candidate.allows("k") else { return false }
            let path = candidate.pathComponents
            return !(path.count > ownPath.count && Array(path.prefix(ownPath.count)) == ownPath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - The sidebar's layout

/// One account's input to ``MailboxTree/layout(accounts:outboxCount:)``.
public struct SidebarAccountInput: Sendable, Hashable {
    public let accountId: Int64
    public let rows: [MailboxTreeRow]
    public let showSubscribedOnly: Bool
    /// The account's drafts, sent and trash folders, as the server numbers them.
    public let pinnedRemoteIds: Set<Int64>
    /// The user chose "Show all folders" for this account.
    public let showsAllFolders: Bool
    /// A provisioned account that cannot connect (ADR-0086): no folders at all.
    public let isDisabled: Bool

    public init(
        accountId: Int64,
        rows: [MailboxTreeRow],
        showSubscribedOnly: Bool = false,
        pinnedRemoteIds: Set<Int64> = [],
        showsAllFolders: Bool = false,
        isDisabled: Bool = false
    ) {
        self.accountId = accountId
        self.rows = rows
        self.showSubscribedOnly = showSubscribedOnly
        self.pinnedRemoteIds = pinnedRemoteIds
        self.showsAllFolders = showsAllFolders
        self.isDisabled = isDisabled
    }
}

/// One row of an account's section, in drawing order.
public enum SidebarItem: Sendable, Hashable, Identifiable {
    /// A top-level folder with its subtree.
    case mailbox(MailboxNode)
    /// The starred messages of the Inbox right above it.
    case favorites(inboxId: Int64)
    /// "Show all folders" (`expanded` false) or "Collapse folders" (`expanded` true).
    case folderToggle(expanded: Bool)

    public var id: String {
        switch self {
        case .mailbox(let node): "mailbox:" + node.id
        case .favorites(let inboxId): "favorites:\(inboxId)"
        case .folderToggle: "folderToggle"
        }
    }
}

public struct SidebarAccountLayout: Sendable, Hashable {
    public let accountId: Int64
    public let items: [SidebarItem]
    /// Every folder of the account after the subscribed filter, collapsed or not: what drop
    /// targets and the move picker work from.
    public let tree: [MailboxNode]

    public init(accountId: Int64, items: [SidebarItem], tree: [MailboxNode]) {
        self.accountId = accountId
        self.items = items
        self.tree = tree
    }
}

/// The entries above the accounts, which are selections rather than folders.
public enum SidebarVirtualEntry: Sendable, Hashable {
    case priorityInbox
    /// The sum of every top-level Inbox's unread count.
    case unifiedInbox(unreadCount: Int)
}

public struct SidebarLayout: Sendable, Hashable {
    public let virtualEntries: [SidebarVirtualEntry]
    public let accounts: [SidebarAccountLayout]
    /// Nil hides the Outbox entry.
    public let outboxCount: Int?

    public init(virtualEntries: [SidebarVirtualEntry], accounts: [SidebarAccountLayout], outboxCount: Int?) {
        self.virtualEntries = virtualEntries
        self.accounts = accounts
        self.outboxCount = outboxCount
    }
}

extension MailboxTree {
    /// The whole sidebar, from rows, as the web client's `Navigation.vue` lays it out (§3.1).
    ///
    /// - Priority inbox always; All inboxes only with more than one account.
    /// - "Show only subscribed folders" drops unsubscribed rows before the tree is built.
    /// - A Favorites entry follows every top-level Inbox.
    /// - Inbox, Drafts, Sent and Trash -- by role or by the account's configured ids -- are
    ///   always shown. With more than one other top-level folder, the others hide behind a
    ///   trailing toggle unless the account shows all folders.
    /// - A disabled account has no rows at all.
    /// - The Outbox entry only exists while the outbox has messages.
    public static func layout(accounts: [SidebarAccountInput], outboxCount: Int) -> SidebarLayout {
        var unifiedUnread = 0
        let sections = accounts.map { input -> SidebarAccountLayout in
            let rows = input.showSubscribedOnly ? input.rows.filter(\.isSubscribed) : input.rows
            let tree = build(from: rows)
            for node in tree where node.row?.specialRole?.lowercased() == "inbox" {
                unifiedUnread += node.unreadCount
            }
            guard !input.isDisabled else {
                return SidebarAccountLayout(accountId: input.accountId, items: [], tree: [])
            }
            let collapsible = tree.filter { !isPinned($0, input) }.count > 1
            var items: [SidebarItem] = []
            for node in tree {
                if !collapsible || input.showsAllFolders || isPinned(node, input) {
                    items.append(.mailbox(node))
                }
                if let row = node.row, row.specialRole?.lowercased() == "inbox" {
                    items.append(.favorites(inboxId: row.id))
                }
            }
            if collapsible {
                items.append(.folderToggle(expanded: input.showsAllFolders))
            }
            return SidebarAccountLayout(accountId: input.accountId, items: items, tree: tree)
        }
        var virtual: [SidebarVirtualEntry] = [.priorityInbox]
        if accounts.count > 1 {
            virtual.append(.unifiedInbox(unreadCount: unifiedUnread))
        }
        return SidebarLayout(
            virtualEntries: virtual,
            accounts: sections,
            outboxCount: outboxCount > 0 ? outboxCount : nil
        )
    }

    private static let pinnedRoles: Set<String> = ["inbox", "drafts", "sent", "trash"]

    private static func isPinned(_ node: MailboxNode, _ input: SidebarAccountInput) -> Bool {
        guard let row = node.row else { return false }
        if let role = row.specialRole?.lowercased(), pinnedRoles.contains(role) { return true }
        if let remoteId = row.remoteId, input.pinnedRemoteIds.contains(remoteId) { return true }
        return false
    }
}
