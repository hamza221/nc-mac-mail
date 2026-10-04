// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The sidebar's Contacts section, one per signed-in login (ADR-0070): All contacts,
/// Favorites, each enabled address book, the contact groups, Recently contacted
/// ([ux-spec.md](../../../docs/product/ux-spec.md#contacts-ws-35)).
///
/// Lives inside `SidebarView`'s `List(selection:)`; every row is a
/// `SidebarSelection.contacts(sessionId:scope:)` tag, so selecting one routes the content
/// column to ``ContactsListView``. The Teams rows are `TeamsSidebarRows` (WS-37), which draw
/// nothing on a server without the Circles app.
struct ContactsSidebarSection: View {
    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser

    var body: some View {
        ForEach(session.accounts) { account in
            ContactsLoginSection(
                model: browser.login(account.id),
                title: session.accounts.count > 1
                    ? String(localized: "Contacts · \(account.loginName)") : String(localized: "Contacts"))
        }
    }
}

private struct ContactsLoginSection: View {
    let model: ContactsLoginModel
    let title: String

    var body: some View {
        Section {
            row(String(localized: "All contacts"), .allContacts, .all, count: people.count)
            row(String(localized: "Favorites"), .star, .favorites, count: people.filter(\.isFavorite).count)
            ForEach(ownBooks, id: \.id) { book in
                if let id = book.id {
                    row(
                        book.displayName ?? String(localized: "Address book"), .contacts, .addressBook(id),
                        count: people.filter { $0.record.addressBookId == id }.count)
                }
            }
            ForEach(model.groups) { group in
                row(group.name, .group, .group(group.name), count: group.count)
            }
            TeamsSidebarRows(model: model)
            if model.books.contains(where: { $0.isEnabled && ContactsListing.isRecentlyContacted($0) }) {
                row(
                    String(localized: "Recently contacted"), .recentlyContacted, .recent,
                    count: people.filter { model.recentBookIds.contains($0.record.addressBookId) }.count)
            }
        } header: {
            AddressBooksSectionHeader(title: title, model: model)
        }
    }

    private var people: [ContactEntry] { model.entries.filter { !$0.record.isGroup } }

    /// Enabled books, Recently contacted aside: it has its own row, as in web Contacts.
    private var ownBooks: [AddressBookRecord] {
        model.books.filter { $0.isEnabled && !ContactsListing.isRecentlyContacted($0) }
    }

    private func row(_ title: String, _ symbol: MailSymbol, _ scope: ContactsScope, count: Int) -> some View {
        NCNavigationItem(title, icon: symbol.symbol, count: count)
            .accessibilityElement(children: .combine)
            .tag(SidebarSelection.contacts(sessionId: model.sessionId, scope: scope))
    }
}
