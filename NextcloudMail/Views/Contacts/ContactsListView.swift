// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The content column for a Contacts selection: one scope's people, favourites first and then
/// in the Contacts sort order, searchable through `contactSearch`, multi-selectable
/// ([ux-spec.md](../../../docs/product/ux-spec.md#contacts-ws-35)).
struct ContactsListView: View {
    let sessionId: String
    let scope: ContactsScope

    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.openComposer) private var openComposer
    @AppStorage(ContactsSortOrder.storageKey) private var orderKey = ContactsSortOrder.default.rawValue

    var body: some View {
        @Bindable var browser = browser
        let model = browser.login(sessionId)
        let rows = ContactsListing.rows(
            model.entries, scope: scope, recentBookIds: model.recentBookIds, matching: browser.searchMatches,
            order: order)
        List(selection: $browser.selection) {
            ForEach(rows) { entry in
                ContactRow(entry: entry, order: order, avatar: session.store.avatarLoader(for: entry.emails.first))
                    .tag(entry.id)
                    .contextMenu { menu(for: entry, model: model) }
            }
        }
        .overlay {
            TeamScopeOverlay(sessionId: sessionId, scope: scope) { emptyState(model: model, isEmpty: rows.isEmpty) }
        }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: Text("Search contacts"))
        .task(id: "\(sessionId)|\(browser.searchText)") {
            // A keystroke's worth of debounce; the FTS query itself is a few milliseconds.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await browser.search(browser.searchText, sessionId: sessionId)
        }
        .onChange(of: scope) { _, _ in browser.selection = [] }
        .onChange(of: sessionId) { _, _ in
            browser.selection = []
            browser.searchText = ""
        }
        .toolbar {
            ToolbarItemGroup {
                Picker(selection: $orderKey) {
                    ForEach(ContactsSortOrder.allCases) { order in
                        Text(order.title).tag(order.rawValue)
                    }
                } label: {
                    Text("Sort contacts by")
                }
                .pickerStyle(.menu)
                .help(String(localized: "Sort contacts by"))
                Button {
                    browser.beginNewContact(sessionId: sessionId, scope: scope)
                } label: {
                    Label {
                        Text("New contact")
                    } icon: {
                        MailSymbol.add.view(size: .small, label: .decorative)
                    }
                }
                .disabled(ContactsActions.defaultBook(for: scope, books: model.books) == nil)
                .help(
                    ContactsActions.defaultBook(for: scope, books: model.books) == nil
                        ? String(localized: "There is no address book you can add contacts to.")
                        : String(localized: "New contact"))
            }
        }
        .onDeleteCommand {
            // One contact at a time here; deleting a selection is WS-36's batch action.
            guard browser.selection.count == 1, let id = browser.selection.first,
                let entry = model.entry(id: id)
            else { return }
            browser.requestDelete([entry.record])
        }
        .navigationTitle(title(model: model))
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !browser.pendingDelete.isEmpty }, set: { if !$0 { browser.pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await browser.confirmDelete(sessionId: sessionId) }
            }
        } message: {
            Text("It is deleted from the server as well, as soon as this Mac is online.")
        }
        .alert(
            "Contacts",
            isPresented: Binding(get: { browser.failure != nil }, set: { if !$0 { browser.failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.failure ?? "")
        }
    }

    private var deleteTitle: String {
        let records = browser.pendingDelete
        if records.count == 1, let name = records.first?.displayName, !name.isEmpty {
            return String(localized: "Delete \(name)?")
        }
        return String(localized: "Delete \(records.count) contacts?")
    }

    private var order: ContactsSortOrder { ContactsSortOrder(rawValue: orderKey) ?? .default }

    private func title(model: ContactsLoginModel) -> String {
        switch scope {
        case .all: String(localized: "All contacts")
        case .favorites: String(localized: "Favorites")
        case .addressBook(let id): model.book(id: id)?.displayName ?? String(localized: "Address book")
        case .group(let name): name
        case .team: String(localized: "Team")
        case .recent: String(localized: "Recently contacted")
        }
    }

    @ViewBuilder
    private func menu(for entry: ContactEntry, model: ContactsLoginModel) -> some View {
        let book = model.book(id: entry.record.addressBookId)
        let canEdit = ContactsActions.readOnlyReason(book) == nil
        if let email = entry.emails.first {
            Button("New message") {
                openComposer(.new(accountId: model.accountIds.first, mailto: ContactCardContentLinks.mailto(email)))
            }
        }
        Button(entry.isFavorite ? "Remove from favorites" : "Add to favorites") {
            browser.toggleFavorite(entry.record, sessionId: sessionId)
        }
        .disabled(!canEdit)
        Divider()
        Button("Delete", role: .destructive) { browser.requestDelete([entry.record]) }
            .disabled(!canEdit)
    }

    @ViewBuilder
    private func emptyState(model: ContactsLoginModel, isEmpty: Bool) -> some View {
        if model.hasLoaded && isEmpty {
            if browser.searchMatches != nil {
                ContentUnavailableView.search(text: browser.searchText)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(scope == .favorites ? "No favorites yet" : "No contacts")
                    } icon: {
                        (scope == .favorites ? MailSymbol.favoriteOff : MailSymbol.allContacts)
                            .view(size: .large, label: .decorative)
                    }
                } description: {
                    if scope == .favorites {
                        Text("Star a contact to see it here.")
                    }
                }
            }
        }
    }
}

/// One person in the list: avatar, the sort order's name, the first address or the
/// organisation, and the star.
private struct ContactRow: View {
    let entry: ContactEntry
    let order: ContactsSortOrder
    let avatar: (@Sendable () async throws -> Image)?

    var body: some View {
        let name = entry.displayName(order: order)
        NCListItem(
            name.isEmpty ? String(localized: "No name") : name,
            subtitle: entry.emails.first ?? entry.organization
        ) {
            NCAvatar(displayName: name, user: entry.emails.first, size: .medium, label: .decorative, load: avatar)
        } details: {
            if entry.isFavorite {
                MailSymbol.star.view(size: .small, label: .text("Favorite"))
            }
        }
    }
}

/// `mailto:` for one address, shared by the list and the detail pane.
enum ContactCardContentLinks {
    static func mailto(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }
}
