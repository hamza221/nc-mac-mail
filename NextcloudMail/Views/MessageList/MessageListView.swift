// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI

/// The middle column: one list — a mailbox, the merged inboxes, Priority inbox or Favorites —
/// threaded or flat, in sections, windowed over the database.
///
/// There is no spinner anywhere in this file. A mailbox that is still filling shows the rows
/// it already has, and one with none yet says so in words. The network never gets a chance
/// to make this view wait, because nothing here can reach it.
struct MessageListView: View {
    @Bindable var model: MessageListStore
    let navigation: NavigationState
    let isOffline: Bool
    /// Set by WS-11's `.searchable`. Nil is the ordinary list.
    var filter: MessageListFilter?
    /// The right-click menu's, hover's and bulk header's actions. Nil draws none of them.
    var triage: TriageContext?

    /// Installed by the shell. Absent (previews, tests), the server defaults apply and the
    /// view-options menu is not drawn.
    @Environment(MessageListPreferenceStore.self) private var preferenceStore: MessageListPreferenceStore?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.ncTheme) private var theme

    /// Everything that decides which queries are open. `.task(id:)` restarts on any change,
    /// which is what replaces the observations rather than adding to them.
    private struct Query: Equatable {
        var source: MessageListSource?
        var view: ListView
        var filter: MessageListFilter?
        var preferences: MessageListPreferences.Querying
    }

    private var preferences: MessageListPreferences {
        preferenceStore?.preferences ?? MessageListPreferences()
    }

    private var query: Query {
        Query(
            source: MessageListSource(navigation.selection),
            view: navigation.listView,
            filter: filter,
            preferences: preferences.querying
        )
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        MessageListCell(
                            row: row,
                            model: model,
                            isCompact: preferences.isCompact,
                            triage: triage,
                            openInWindow: { openWindow(id: MessageWindowScene.id, value: $0) }
                        )
                        .onAppear { model.rowAppeared(row) }
                    }
                } header: {
                    if let title = section.title { Text(verbatim: title) }
                }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let triage {
                TriageContextMenu(context: triage, targetIds: ids)
            }
            if ids.count == 1, let id = ids.first {
                Divider()
                Button {
                    openWindow(id: MessageWindowScene.id, value: id)
                } label: {
                    Text("Open in New Window")
                }
            }
        } primaryAction: { ids in
            // Double-click or Return: in the list layout that opens the message in place; in
            // the split layouts it is already open beside the list, so it gets a window.
            guard ids.count == 1, let id = ids.first else { return }
            if preferences.layout == .list {
                model.selection = [id]
                model.openedMessageId = id
            } else {
                openWindow(id: MessageWindowScene.id, value: id)
            }
        }
        .onCommand(#selector(NSText.selectAll(_:))) { model.selectAll() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.selection.count > 1 {
                BulkSelectionHeader(model: model, triage: triage)
            }
        }
        .overlay { emptyState }
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .task(id: query) {
            model.show(query.source, view: query.view, filter: query.filter, preferences: query.preferences)
        }
        .onChange(of: isOffline, initial: true) { _, newValue in model.isOffline = newValue }
        // A layout change swaps this view for a new one, possibly appearing before this one
        // goes; the model counts views and stops only when the last has gone.
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker(String(localized: "Grouping"), selection: listViewBinding) {
                Text("Threaded").tag(ListView.threaded)
                Text("Flat").tag(ListView.flat)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("Group messages by thread"))
        }
        if let preferenceStore {
            ToolbarItem {
                MessageListOptionsMenu(store: preferenceStore)
            }
        }
    }

    /// Writing through `NavigationState` is what makes the choice survive a relaunch
    /// ([ADR-0040](../../../docs/decisions/0040-list-view-is-remembered-per-app.md)).
    private var listViewBinding: Binding<ListView> {
        Binding(get: { navigation.listView }, set: { navigation.setListView($0) })
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.presentation {
        case .rows:
            EmptyView()
        case .noMailboxSelected:
            ContentUnavailableView {
                Label {
                    Text("No mailbox selected")
                } icon: {
                    MailSymbol.inbox.view(size: .large, label: .decorative)
                }
            }
        case .mirroring:
            ContentUnavailableView {
                Label {
                    Text("Downloading messages")
                } icon: {
                    MailSymbol.sync.view(size: .large, label: .decorative)
                }
            } description: {
                Text("This mailbox is still being copied. Its messages appear here as they arrive.")
            }
        case .emptyMailbox:
            ContentUnavailableView {
                Label {
                    Text("No messages")
                } icon: {
                    MailSymbol.inbox.view(size: .large, label: .decorative)
                }
            }
        case .noResults(let query) where query.isEmpty:
            // Chips alone (Unread, Has attachment) narrow without any text to quote.
            ContentUnavailableView.search
        case .noResults(let query):
            ContentUnavailableView.search(text: query)
        case .notDownloaded:
            ContentUnavailableView {
                Label {
                    Text("Not downloaded yet")
                } icon: {
                    MailSymbol.inbox.view(size: .large, label: .decorative)
                }
            } description: {
                Text("This mailbox has not been copied to this Mac. It downloads when you are back online.")
            }
        }
    }
}

/// One row, its drag, and the quick actions that appear while the pointer is over it.
private struct MessageListCell: View {
    let row: MessageRow
    let model: MessageListStore
    let isCompact: Bool
    let triage: TriageContext?
    let openInWindow: (Int64) -> Void

    @State private var isHovering = false
    @Environment(\.ncTheme) private var theme

    var body: some View {
        MessageListRow(
            row: row,
            avatar: model.avatarLoader(for: row.senderEmail),
            adornments: model.adornments(for: row),
            isCompact: isCompact
        )
        .overlay(alignment: .topTrailing) {
            if isHovering, let triage {
                MessageHoverActions(row: row, triage: triage, openInWindow: openInWindow)
            }
        }
        .onHover { isHovering = $0 }
        .draggable(model.dragPayload(for: row)) {
            // The preview is the subject, as the web's `draggableLabel`, never a rendered row.
            Text(verbatim: row.subject ?? String(localized: "No subject"))
                .padding(theme.metrics.spacing.tight)
        }
    }
}

/// Star, read/unread, archive, delete and "…", for the row under the pointer only.
///
/// They act on that row without selecting it: selecting would open it and mark it read,
/// which is not what pointing at a star and clicking it asks for.
private struct MessageHoverActions: View {
    let row: MessageRow
    let triage: TriageContext
    let openInWindow: (Int64) -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        HStack(spacing: theme.metrics.spacing.hairline) {
            button(.star, label: row.isFlagged ? String(localized: "Unstar") : String(localized: "Star"))
            button(
                .unread,
                label: row.isSeen ? String(localized: "Mark as unread") : String(localized: "Mark as read"))
            button(.archive, label: TriageAction.archive.title)
            button(.delete, label: TriageAction.delete.title)
            Menu {
                TriageContextMenu(context: triage, targetIds: [row.id])
                Divider()
                Button {
                    openInWindow(row.id)
                } label: {
                    Text("Open in New Window")
                }
            } label: {
                MailSymbol.more.view(size: .small, label: .text("More actions"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(theme.metrics.spacing.tight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: theme.metrics.radius.small))
    }

    private func button(_ action: TriageAction, label: String) -> some View {
        Button {
            Task { await triage.perform(action, on: [row.id]) }
        } label: {
            (action.symbol ?? .more).view(size: .small, label: .content(label))
        }
        .buttonStyle(.borderless)
        .help(Text(verbatim: label))
    }
}

/// "N selected" and the actions that make sense for many at once.
private struct BulkSelectionHeader: View {
    let model: MessageListStore
    let triage: TriageContext?

    @Environment(\.ncTheme) private var theme

    var body: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            Text("\(model.selection.count) selected")
                .font(.headline)
            Spacer()
            if let triage {
                action(.unread, triage: triage)
                action(.star, triage: triage)
                action(.important, triage: triage)
                action(.archive, triage: triage)
                action(.delete, triage: triage)
            }
            Button {
                model.selection = []
            } label: {
                Text("Clear selection")
            }
        }
        .padding(.horizontal, theme.metrics.spacing.standard)
        .padding(.vertical, theme.metrics.spacing.tight)
        .background(.bar)
    }

    private func action(_ action: TriageAction, triage: TriageContext) -> some View {
        Button {
            Task { await triage.perform(action) }
        } label: {
            if let symbol = action.symbol ?? (action == .important ? .important : nil) {
                symbol.view(size: .small, label: .text(action.label))
            } else {
                Text(action.label)
            }
        }
        .disabled(!triage.isEnabled(action))
        .help(Text(action.label))
    }
}

/// Layout, compact mode, sort order and favorites on top, written to the server. WS-38's
/// settings window will carry the same controls; until then this is where they live.
private struct MessageListOptionsMenu: View {
    let store: MessageListPreferenceStore

    var body: some View {
        Menu {
            Picker(String(localized: "Layout"), selection: binding(\.layout) { await store.set(layout: $0) }) {
                ForEach(MessageListLayout.allCases) { layout in
                    Text(verbatim: layout.title).tag(layout)
                }
            }
            Toggle(
                String(localized: "Compact Mode"), isOn: binding(\.isCompact) { await store.set(isCompact: $0) })
            Divider()
            Picker(
                String(localized: "Sort"), selection: binding(\.sortOrder) { await store.set(sortOrder: $0) }
            ) {
                Text("Newest First").tag(MessageSortOrder.newest)
                Text("Oldest First").tag(MessageSortOrder.oldest)
            }
            Toggle(
                String(localized: "Favorites on Top"),
                isOn: binding(\.favoritesOnTop) { await store.set(favoritesOnTop: $0) })
        } label: {
            MailSymbol.layout.view(label: .text("View options"))
        }
        .help(Text("View options"))
    }

    /// Reads the mirrored value and queues the change; the queue writes the row locally in
    /// the same transaction, so the menu reflects it at once and offline.
    private func binding<Value>(
        _ keyPath: KeyPath<MessageListPreferences, Value>,
        set: @escaping @MainActor (Value) async -> Void
    ) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in Task { await set(value) } }
        )
    }
}
