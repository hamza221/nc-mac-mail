// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import SwiftUI

/// §4.7's inline picker, "Select a mailbox": a pop-up of one account's folders with
/// subfolders indented, for the account's default folders and a filter's "Move into folder".
///
/// Reads the mirror (the view never touches the network) and offers only the folders that
/// can take a message: selectable, and granting the `i` right.
struct InlineMailboxPicker: View {
    let title: String
    let accountId: Int64
    let store: MailStore
    @Binding var selection: Int64?

    @State private var options: [MoveDestination] = []

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Select a mailbox").tag(Int64?.none)
            ForEach(options) { option in
                // Non-breaking spaces: a menu item trims ordinary leading whitespace.
                Text(String(repeating: "\u{00A0}\u{00A0}\u{00A0}", count: option.depth) + option.displayName)
                    .tag(Int64?.some(option.id))
            }
        }
        .task(id: accountId) {
            options = await Self.options(accountId: accountId, store: store)
        }
    }

    static func options(accountId: Int64, store: MailStore) async -> [MoveDestination] {
        guard let records = try? await store.mailboxes(accountId: accountId) else { return [] }
        let pickable = Set(records.filter { $0.isSelectable && MailboxRights(mailbox: $0).canInsert }.map(\.id))
        return MailboxTree.build(from: records.map(\.treeRow))
            .flatMap { $0.destinations() }
            .filter { pickable.contains($0.id) }
    }
}
