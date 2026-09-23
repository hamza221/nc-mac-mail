// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// One folder a selection can move to.
struct MoveDestination: Identifiable, Equatable, Sendable {
    let id: Int64
    let displayName: String
    /// How deep in the mailbox tree, for the indent. Zero while a filter is running, because
    /// a match whose parent does not match would otherwise be indented under nothing.
    let depth: Int
}

/// The list behind Move ▾: every subscribed, selectable folder of the selection's account,
/// filtered as you type.
///
/// Container rows are left out. A `\noselect` mailbox cannot hold a message, so offering it
/// as a destination is offering an error
/// ([ux-spec.md](../../docs/product/ux-spec.md#sidebar)).
struct MoveDestinationList: View {
    let context: TriageContext
    let onPick: (Int64) -> Void

    @State private var destinations: [MoveDestination] = []
    @State private var filter = ""
    @Environment(\.ncTheme) private var theme

    private var matches: [MoveDestination] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return destinations }
        return
            destinations
            .filter { $0.displayName.localizedCaseInsensitiveContains(query) }
            .map { MoveDestination(id: $0.id, displayName: $0.displayName, depth: 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            TextField(String(localized: "Filter folders"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Filter folders"))
            if matches.isEmpty {
                // `.secondary` rather than a token: `NCColorTokens` has no muted-text
                // colour, and the system role is the one thing that is not a hard-coded
                // colour. See docs/feedback/library-feedback.md.
                Text("No folders match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { destination in
                            Button {
                                onPick(destination.id)
                            } label: {
                                HStack(spacing: theme.metrics.spacing.tight) {
                                    MailSymbol.folder.view(size: .small, label: .decorative)
                                    Text(destination.displayName)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, theme.metrics.spacing.standard * Double(destination.depth))
                            }
                            .buttonStyle(.tertiary)
                            .accessibilityLabel(Text("Move to \(destination.displayName)"))
                        }
                    }
                }
                .frame(maxHeight: Self.listHeight)
            }
        }
        .padding(theme.metrics.spacing.standard)
        .frame(width: Self.width)
        .task { destinations = await context.moveDestinations() }
    }

    /// The popover's shape. Window chrome rather than a spacing or radius token, so it is not
    /// a theme metric — the same reasoning `RootSplitView` applies to its column widths.
    private static let width = 280.0
    private static let listHeight = 320.0
}

extension MailboxNode {
    /// The tree, flattened depth-first, keeping only the rows a message can actually land in.
    func destinations() -> [MoveDestination] {
        var flattened: [MoveDestination] = []
        if let row, isSelectable, isSubscribed {
            flattened.append(MoveDestination(id: row.id, displayName: displayName, depth: depth))
        }
        for child in children { flattened.append(contentsOf: child.destinations()) }
        return flattened
    }
}
