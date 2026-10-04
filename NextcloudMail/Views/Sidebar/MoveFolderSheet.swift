// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NextcloudUI
import SwiftUI

/// "Move folder": the top level ("/") and every folder with right `k`, except the folder
/// itself and anything below it (`MailboxTree.moveTargets(for:in:)`). Move queues
/// `moveMailbox`; the sheet closes at once because the local change already happened.
struct MoveFolderSheet: View {
    let source: SidebarStore.MoveSource
    let model: SidebarStore

    @State private var choice: Choice? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    /// A `List` selection value that can be the root, which has no row.
    enum Choice: Hashable {
        case root
        case folder(Int64)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Choose target folder")
                .font(.headline)
            List(selection: $choice) {
                Text(verbatim: "/").tag(Choice.root)
                ForEach(targets) { row in
                    Text(verbatim: row.pathComponents.joined(separator: " / "))
                        .tag(Choice.folder(row.id))
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { move() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
        }
        .padding(theme.metrics.spacing.standard)
        .frame(minWidth: 360)
    }

    private var targets: [MailboxTreeRow] {
        MailboxTree.moveTargets(for: source.row, in: model.mailboxRows[source.accountId] ?? [])
    }

    private func move() {
        let parent: MailboxTreeRow? =
            switch choice {
            case .folder(let id): targets.first { $0.id == id }
            case .root, nil: nil
            }
        let source = source
        Task { await model.moveFolder(source.row, under: parent, accountId: source.accountId) }
        dismiss()
    }
}
