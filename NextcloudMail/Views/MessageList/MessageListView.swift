// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The middle column: one mailbox, threaded or flat, windowed over the database.
///
/// There is no spinner anywhere in this file and no `ProgressView` in this workstream. A
/// mailbox that is still filling shows the rows it already has, and one with none yet says
/// so in words. The network never gets a chance to make this view wait, because nothing
/// here can reach it.
struct MessageListView: View {
    @Bindable var model: MessageListStore
    let navigation: NavigationState
    let isOffline: Bool
    /// Set by WS-11's `.searchable`. Nil is the ordinary mailbox list.
    var filter: MessageListFilter?
    /// The right-click menu's actions. Nil draws no menu.
    var triage: TriageContext?

    /// Everything that decides which query is open. `.task(id:)` restarts on any change,
    /// which is what replaces the observation rather than adding one.
    private struct Query: Equatable {
        var mailboxId: Int64?
        var view: ListView
        var filter: MessageListFilter?
    }

    private var query: Query {
        Query(mailboxId: navigation.selectedMailboxID, view: navigation.listView, filter: filter)
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        MessageListRow(row: row, avatar: model.avatarLoader(for: row.senderEmail))
                            .onAppear { extendWindowIfLast(row) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let triage {
                TriageContextMenu(context: triage, targetIds: ids)
            }
        }
        .overlay { emptyState }
        .navigationTitle(model.mailbox?.displayName ?? String(localized: "Messages"))
        .toolbar { viewPicker }
        .task(id: query) {
            model.show(mailbox: query.mailboxId, view: query.view, filter: query.filter)
        }
        .onChange(of: isOffline, initial: true) { _, newValue in model.isOffline = newValue }
        .onDisappear { model.stop() }
    }

    /// Scrolling extends the window. The last row appearing is the signal, and the extension
    /// has no spinner because the rows it asks for are already on this machine.
    private func extendWindowIfLast(_ row: MessageRow) {
        guard row.id == model.rows.last?.id else { return }
        model.loadMore()
    }

    @ToolbarContentBuilder
    private var viewPicker: some ToolbarContent {
        ToolbarItem {
            Picker(String(localized: "Grouping"), selection: listViewBinding) {
                Text("Threaded").tag(ListView.threaded)
                Text("Flat").tag(ListView.flat)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("Group messages by thread"))
        }
    }

    /// Writing through `NavigationState` is what makes the choice survive a relaunch: the
    /// setter persists it to `meta` and `load()` reads it back on the next launch. One key for
    /// the app rather than one per account
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
