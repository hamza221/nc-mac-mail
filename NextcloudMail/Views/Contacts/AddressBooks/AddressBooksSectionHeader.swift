// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// The Contacts section's caption with its ⋯ menu: Manage address books…, Import vCard…,
/// Contacts settings… ([ux-spec.md](../../../../docs/product/ux-spec.md#address-books-import-merge-ws-36)).
///
/// Also where the social-avatar auto-update runs, because it is on screen for as long as the
/// Contacts section is: see ``ContactsSocialAutoUpdate``.
struct AddressBooksSectionHeader: View {
    let title: String
    let model: ContactsLoginModel

    @Environment(ContactsBrowser.self) private var browser
    @State private var route: Route?
    @AppStorage(ContactsSocialAutoUpdate.storageKey) private var autoUpdate = false

    enum Route: String, Identifiable {
        case manage
        case importCards
        case settings
        var id: String { rawValue }
    }

    var body: some View {
        HStack {
            NCNavigationCaption(title)
            Spacer()
            Menu {
                Button("Manage address books…") { route = .manage }
                Button("Import vCard…") { route = .importCards }
                    .disabled(model.books.allSatisfy { $0.isReadOnly || ContactsListing.isRecentlyContacted($0) })
                Divider()
                Button("Contacts settings…") { route = .settings }
            } label: {
                MailSymbol.more.view(size: .small, label: .text("Address books and contacts settings"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Address books and contacts settings"))
        }
        .sheet(item: $route) { route in
            switch route {
            case .manage: AddressBooksSheet(sessionId: model.sessionId)
            case .importCards: VCardImportSheet(sessionId: model.sessionId)
            case .settings: ContactsSettingsView()
            }
        }
        .task(id: autoUpdate ? browser.selection : []) {
            guard autoUpdate, browser.selection.count == 1, let id = browser.selection.first,
                let entry = model.entry(id: id)
            else { return }
            await ContactsSocialAutoUpdate.viewed(entry.record, model: model, browser: browser)
        }
    }
}
