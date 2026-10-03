// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import SwiftUI

/// Where in the mailbox tree the user was, kept for a relaunch rather than a settings screen —
/// [ux-spec.md](../../docs/product/ux-spec.md#window) is explicit that this is restoration,
/// not a preference.
///
/// `SidebarView` writes the selection, `MessageListView` reads it, and ``mailboxDidChange``
/// carries it on to every `SyncScheduler`: the mailbox being read syncs on the shorter
/// foreground interval and is never deep-reconciled underneath the scroll view.
@MainActor
@Observable
final class NavigationState {
    private(set) var selectedMailboxID: Int64?
    private(set) var listView: ListView = .threaded

    /// Called with every selection, including the one `load()` restores. `AppSession` sets it
    /// so that the sync engine hears about a selection without a view having to reach for a
    /// scheduler.
    var mailboxDidChange: (@MainActor (Int64?) -> Void)?

    private let store: MailStore

    private enum MetaKey {
        static let mailbox = "navigation.selectedMailboxId"
        static let listView = "navigation.listView"
    }

    init(store: MailStore) {
        self.store = store
    }

    /// Reads what was persisted the last time any of the setters below ran. Safe to call more
    /// than once; each read is independent of the others.
    func load() async {
        selectedMailboxID = (try? await store.metaValue(forKey: MetaKey.mailbox)).flatMap { Int64($0) }
        if let raw = try? await store.metaValue(forKey: MetaKey.listView), let value = ListView(rawValue: raw) {
            listView = value
        }
        mailboxDidChange?(selectedMailboxID)
    }

    func selectMailbox(_ id: Int64?) {
        selectedMailboxID = id
        mailboxDidChange?(id)
        Task { try? await store.setMetaValue(id.map(String.init), forKey: MetaKey.mailbox) }
    }

    func setListView(_ value: ListView) {
        listView = value
        Task { try? await store.setMetaValue(value.rawValue, forKey: MetaKey.listView) }
    }
}
