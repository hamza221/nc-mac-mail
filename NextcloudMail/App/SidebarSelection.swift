// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the sidebar has selected, which decides what the content and detail columns show
/// ([ux-spec.md](../../docs/product/ux-spec.md#what-the-sidebar-can-select-ws-25)).
///
/// Codable because it is what `NavigationState` persists for a relaunch. Ids are local
/// (ADR-0033) except `sessionId`, which is ``AccountSession/id`` — the login a contacts
/// section belongs to (ADR-0070), stable across launches.
nonisolated enum SidebarSelection: Hashable, Codable, Sendable {
    case mailbox(Int64)
    case unifiedInbox
    case priorityInbox
    case favorites(inboxId: Int64)
    case outbox
    case contacts(sessionId: String, scope: ContactsScope)

    /// The mailbox the v1 message list shows for this selection. Only a real mailbox has
    /// one; the virtual selections get their own lists in wave 3.
    var mailboxId: Int64? {
        if case .mailbox(let id) = self { id } else { nil }
    }
}

/// One entry of a login's Contacts section (ADR-0070).
nonisolated enum ContactsScope: Hashable, Codable, Sendable {
    case all
    case favorites
    /// Local `addressBook.id`.
    case addressBook(Int64)
    /// The vCard `CATEGORIES` value.
    case group(String)
    /// The Team (circle) id.
    case team(String)
    case recent
}

/// The `start-mailbox-id` preference, spelled as the web client spells it
/// (`MailboxThread.vue` saves `mailbox.databaseId`; `Home.vue` opens on it): a mailbox's
/// server id, or `unified` / `priority` for the two virtual inboxes.
///
/// Pure, so the mapping both ways is unit-tested; ``AccountEngine`` does the reading and the
/// queueing.
nonisolated enum StartMailbox {
    static let preferenceKey = "start-mailbox-id"
    /// How long a selection has to stand before it is saved, as the web client's
    /// `START_MAILBOX_DEBOUNCE`.
    static let settleDelay: Duration = .seconds(5)

    static let unified = "unified"
    static let priority = "priority"

    /// The preference value for a selection, given the server id of the mailbox it names.
    /// Nil for a selection that is never a start mailbox.
    static func value(for selection: SidebarSelection, remoteMailboxId: Int64?) -> String? {
        switch selection {
        case .mailbox: remoteMailboxId.map(String.init)
        case .unifiedInbox: unified
        case .priorityInbox: priority
        case .favorites, .outbox, .contacts: nil
        }
    }

    /// Whether a selection can become the start mailbox at all, before any lookup.
    static func isCandidate(_ selection: SidebarSelection) -> Bool {
        value(for: selection, remoteMailboxId: 0) != nil
    }

    /// The selection a stored value opens on. `localMailboxId` resolves a server mailbox id
    /// among the login's own mailboxes; a mailbox that no longer exists is no start mailbox,
    /// as in the web client.
    static func selection(for value: String, localMailboxId: (Int64) -> Int64?) -> SidebarSelection? {
        switch value {
        case unified: return .unifiedInbox
        case priority: return .priorityInbox
        default:
            guard let remote = Int64(value), let local = localMailboxId(remote) else { return nil }
            return .mailbox(local)
        }
    }
}
