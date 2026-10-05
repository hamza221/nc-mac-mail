// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// The multi-selection pane's actions: Merge… (exactly two people), Export… and Delete. Delete
/// goes through the list's own confirmation (`ContactsBrowser.requestDelete`).
struct ContactBatchActions: View {
    let sessionId: String

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.ncTheme) private var theme
    @State private var merging: MergePair?
    @State private var export: VCardFile?

    var body: some View {
        let records = browser.selectedContacts(sessionId: sessionId)
        let books = browser.login(sessionId).books
        let readOnly = records.contains { record in
            ContactsActions.readOnlyReason(books.first { $0.id == record.addressBookId }) != nil
        }
        let people = records.filter { !$0.isGroup }
        HStack(spacing: theme.metrics.spacing.standard) {
            Button("Merge…") {
                if people.count == 2 { merging = MergePair(first: people[0], second: people[1]) }
            }
            .disabled(people.count != 2 || records.count != 2 || readOnly)
            .help(
                people.count == 2
                    ? (readOnly
                        ? String(localized: "One of these contacts is in a read-only address book.")
                        : String(localized: "Merge these two contacts into one"))
                    : String(localized: "Select exactly two contacts to merge them."))
            Button("Export…") {
                export = VCardFile(data: VCardExport.data(records), name: VCardExport.fileName(nil))
            }
            Button("Delete", role: .destructive) { browser.requestDelete(records) }
                .disabled(readOnly)
                .help(
                    readOnly
                        ? String(localized: "Some of these contacts are in a read-only address book.")
                        : String(localized: "Delete \(records.count) contacts"))
        }
        .sheet(item: $merging) { pair in
            ContactMergeSheet(sessionId: sessionId, first: pair.first, second: pair.second)
        }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            document: export, contentType: .vCard, defaultFilename: export?.name
        ) { _ in }
    }
}

private struct MergePair: Identifiable {
    let first: ContactRecord
    let second: ContactRecord
    var id: String { "\(first.href)|\(second.href)" }
}
