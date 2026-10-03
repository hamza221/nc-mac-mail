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

    public init(
        id: Int64,
        name: String,
        delimiter: String?,
        specialRole: String?,
        isSelectable: Bool,
        isSubscribed: Bool,
        unreadCount: Int,
        hasSyncFailure: Bool = false
    ) {
        self.id = id
        self.name = name
        self.delimiter = delimiter
        self.specialRole = specialRole
        self.isSelectable = isSelectable
        self.isSubscribed = isSubscribed
        self.unreadCount = unreadCount
        self.hasSyncFailure = hasSyncFailure
    }
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
            rowsByPath[pathComponents(for: row)] = row
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

    /// A flat namespace (`nil` or empty delimiter) keeps the whole name as one component, so
    /// the row can never be split into a parent and a child it does not have.
    private static func pathComponents(for row: MailboxTreeRow) -> [String] {
        guard let delimiter = row.delimiter, !delimiter.isEmpty else { return [row.name] }
        return row.name.components(separatedBy: delimiter)
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
