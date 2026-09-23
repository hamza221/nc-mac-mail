// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The middle column with a search field on it.
///
/// A wrapper around `MessageListView` rather than a second list. WS-08 left a one-property
/// seam — `MessageListStore.filteredSource` — precisely so that results replace the rows of
/// the list that already exists, with its windowing, its selection, its sections and its
/// empty states intact. This view installs that seam and adds the three things search needs
/// around it: the field, the scope control and the coverage footer.
///
/// `RootSplitView` uses this in place of `MessageListView` in its `content` column; the
/// arguments are the same plus the store, which the coverage counter and the results query
/// both read.
struct SearchableMessageList: View {
    @Bindable var model: SearchModel
    let list: MessageListStore
    let navigation: NavigationState
    let isOffline: Bool

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        MessageListView(
            model: list,
            navigation: navigation,
            isOffline: isOffline,
            filter: model.filter
        )
        .searchable(
            text: $model.text,
            placement: .toolbar,
            prompt: Text("Search mail")
        )
        .searchFocused($isFieldFocused)
        .searchScopes($model.scope) {
            Text("This Mailbox").tag(MessageListFilter.Scope.mailbox)
            Text("All Mail").tag(MessageListFilter.Scope.allMail)
        }
        .safeAreaInset(edge: .bottom) {
            SearchCoverageFooter(summary: model.coverageSummary, note: model.unmirroredSummary)
        }
        // The seam goes in once, on appear, and is never replaced: the closure reads the
        // field at the moment the list asks for rows, so there is no window in which a
        // filter is set and its source is not. Until a character is typed the filter is nil
        // and the list is the plain mailbox, which is what makes "once" safe.
        .task {
            list.filteredSource = model.rowSource()
            model.observeCoverage()
        }
        .onChange(of: navigation.selectedMailboxID, initial: true) { _, newValue in
            model.mailboxId = newValue
        }
        // ⌘F and ⌘⇧F land here. A menu command is built outside the window and cannot reach
        // a `@FocusState`, so it bumps a counter and this is what moves the caret.
        .onChange(of: model.focusRequests) { _, _ in
            isFieldFocused = true
        }
        .onDisappear { model.stop() }
    }
}

/// The two sentences ``SearchModel/coverageSummary`` and ``SearchModel/unmirroredSummary``
/// produce, or nothing at all.
///
/// Both strings are decided in the model rather than here, so what the footer says can be
/// asserted without a view test — and so that "when does this appear" is one rule in one
/// place instead of a condition spread across a `body`.
struct SearchCoverageFooter: View {
    let summary: String?
    let note: String?

    @Environment(\.ncTheme) private var theme

    var body: some View {
        if summary != nil || note != nil {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                if let summary { Text(summary) }
                if let note { Text(note) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.metrics.spacing.tight)
            .accessibilityElement(children: .combine)
        }
    }
}
