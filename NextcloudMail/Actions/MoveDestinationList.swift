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
    /// How deep in the mailbox tree, for the indent in the context menu's flat list.
    let depth: Int
}

/// One account's mailbox tree, and which rows can take a message (selectable, `i` right).
struct MoveTree: Equatable, Sendable {
    let nodes: [MailboxNode]
    let pickable: Set<Int64>

    /// §4.7's search: every node whose name matches, anywhere in the tree, labelled with its
    /// full path "Parent / Child". Containers that cannot take a message are left out.
    func search(_ query: String) -> [MoveSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var hits: [MoveSearchHit] = []
        func walk(_ node: MailboxNode) {
            if let row = node.row, pickable.contains(row.id),
                node.displayName.localizedCaseInsensitiveContains(needle)
            {
                hits.append(MoveSearchHit(id: row.id, path: node.path.joined(separator: " / ")))
            }
            node.children.forEach(walk)
        }
        nodes.forEach(walk)
        return hits
    }
}

struct MoveSearchHit: Identifiable, Equatable, Sendable {
    let id: Int64
    let path: String
}

/// "Choose target folder" (§4.7): a search field, breadcrumbs from "/", the current level's
/// folders with a chevron into each one that has children, and a confirm button that stays
/// disabled until a folder is picked.
///
/// Shown in the toolbar's Move popover (ADR-0052) and as the sheet behind Message ▸ Move to
/// Folder…. Picking the folder the messages are already in is a no-op, as on the web.
struct MailboxPicker: View {
    let context: TriageContext
    let selection: Selection
    let onDone: () -> Void

    @State private var tree: MoveTree?
    @State private var trail: [MailboxNode] = []
    @State private var query = ""
    @State private var picked: Int64?
    @State private var sources: Set<Int64> = []
    @Environment(\.ncTheme) private var theme

    private var level: [MailboxNode] { trail.last?.children ?? tree?.nodes ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Choose target folder")
                .font(.headline)
            TextField(String(localized: "Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Search folders"))
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                breadcrumbs
                levelList
            } else {
                searchList
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    guard let picked else { return }
                    onDone()
                    // Its own folder: nothing to do (§4.7).
                    guard !(sources.count == 1 && sources.contains(picked)) else { return }
                    Task { await context.move(selection, to: picked) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
                .disabled(picked == nil)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: Self.width)
        .task {
            await context.actions.refreshAvailability(for: selection)
            tree = await context.moveTree()
            let records = (try? await context.actions.records(for: selection.messageIds)) ?? []
            sources = Set(records.map(\.mailboxId))
        }
    }

    private var confirmTitle: String {
        selection.scope == .threads ? String(localized: "Move thread") : String(localized: "Move message")
    }

    /// "/" then each folder drilled into; choosing one goes back to it.
    private var breadcrumbs: some View {
        let root = NCBreadcrumbSegment(id: "", title: "/")
        let segments = [root] + trail.map { NCBreadcrumbSegment(id: $0.id, title: $0.displayName) }
        return NCBreadcrumbs(segments) { segment in
            guard let index = trail.firstIndex(where: { $0.id == segment.id }) else {
                trail = []
                return
            }
            trail = Array(trail.prefix(index + 1))
        }
    }

    @ViewBuilder
    private var levelList: some View {
        if level.isEmpty {
            empty(String(localized: "No more submailboxes in here"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(level) { node in
                        HStack(spacing: theme.metrics.spacing.tight) {
                            row(id: node.row?.id, title: node.displayName)
                            if !node.children.isEmpty {
                                Button {
                                    trail.append(node)
                                } label: {
                                    MailSymbol.chevronForward.view(
                                        size: .small, label: .text("Open \(node.displayName)"))
                                }
                                .buttonStyle(.icon)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: Self.listHeight)
        }
    }

    @ViewBuilder
    private var searchList: some View {
        let hits = tree?.search(query) ?? []
        if hits.isEmpty {
            empty(String(localized: "No results"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in row(id: hit.id, title: hit.path) }
                }
            }
            .frame(maxHeight: Self.listHeight)
        }
    }

    private func row(id: Int64?, title: String) -> some View {
        let pickable = id.map { tree?.pickable.contains($0) ?? false } ?? false
        return Button {
            picked = id
        } label: {
            HStack(spacing: theme.metrics.spacing.tight) {
                MailSymbol.folder.view(size: .small, label: .decorative)
                Text(title)
                    .fontWeight(picked != nil && picked == id ? .semibold : nil)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.tertiary)
        .disabled(!pickable)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(picked != nil && picked == id ? .isSelected : [])
    }

    private func empty(_ text: String) -> some View {
        // `.secondary`: `NCColorTokens` has no muted-text colour (library-feedback.md).
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Sheet and popover shape: window chrome, not a theme metric.
    private static let width = 320.0
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
