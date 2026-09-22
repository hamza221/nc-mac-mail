// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import SwiftUI

/// Where in the mailbox tree the user was, kept for a relaunch rather than a settings screen —
/// [ux-spec.md](../../docs/product/ux-spec.md#window) is explicit that this is restoration,
/// not a preference.
///
/// `NextcloudMail/Views/Sidebar` (WS-07) and `NextcloudMail/Views/MessageList` (WS-08) read
/// and write these once they exist; this workstream defines the `meta` keys and the
/// persistence so neither has to invent its own. There is nothing to select yet — both
/// columns are still placeholders — so `load()` has something to populate but no view reads
/// it back today.
@MainActor
@Observable
final class NavigationState {
    private(set) var selectedAccountID: String?
    private(set) var selectedMailboxID: Int64?
    private(set) var listView: ListView = .threaded

    private let store: MailStore

    private enum MetaKey {
        static let account = "navigation.selectedAccountId"
        static let mailbox = "navigation.selectedMailboxId"
        static let listView = "navigation.listView"
    }

    init(store: MailStore) {
        self.store = store
    }

    /// Reads what was persisted the last time any of the setters below ran. Safe to call more
    /// than once; each read is independent of the others.
    func load() async {
        selectedAccountID = try? await store.metaValue(forKey: MetaKey.account)
        selectedMailboxID = (try? await store.metaValue(forKey: MetaKey.mailbox)).flatMap { Int64($0) }
        if let raw = try? await store.metaValue(forKey: MetaKey.listView), let value = ListView(rawValue: raw) {
            listView = value
        }
    }

    func selectAccount(_ id: String?) {
        selectedAccountID = id
        Task { try? await store.setMetaValue(id, forKey: MetaKey.account) }
    }

    func selectMailbox(_ id: Int64?) {
        selectedMailboxID = id
        Task { try? await store.setMetaValue(id.map(String.init), forKey: MetaKey.mailbox) }
    }

    func setListView(_ value: ListView) {
        listView = value
        Task { try? await store.setMetaValue(value.rawValue, forKey: MetaKey.listView) }
    }
}
