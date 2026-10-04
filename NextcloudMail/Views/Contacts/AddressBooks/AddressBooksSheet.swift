// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// Every address book of one login, enabled or not: the on/off toggle, rename, share, export,
/// copy the CardDAV URL, delete, and a field to create one. Each change is a queued write that
/// shows in the list at once ([ux-spec.md](../../../../docs/product/ux-spec.md#address-books-import-merge-ws-36)).
struct AddressBooksSheet: View {
    let sessionId: String

    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var newName = ""
    @State private var renaming: Int64?
    @State private var renameText = ""
    @State private var sharing: SharedBook?
    @State private var deleting: AddressBookRecord?
    @State private var export: VCardFile?
    @State private var status: String?

    var body: some View {
        let model = browser.login(sessionId)
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Address books").font(.headline)
            List {
                ForEach(model.books, id: \.url) { book in
                    row(book)
                }
            }
            .frame(minHeight: 220)
            HStack {
                TextField(String(localized: "New address book"), text: $newName)
                    .onSubmit { create(model: model) }
                Button("Create") { create(model: model) }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 560)
        .frame(minHeight: 420)
        .sheet(item: $sharing) { item in
            AddressBookShareSheet(sessionId: sessionId, book: item.book)
        }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            document: export, contentType: .vCard, defaultFilename: export?.name
        ) { result in
            if case .failure(let error) = result {
                ContactsBrowser.logger.error(
                    "address book export not written: \(String(describing: type(of: error)), privacy: .public)")
                status = String(localized: "The address book could not be exported.")
            }
        }
        .confirmationDialog(
            String(localized: "Delete \(deleting?.displayName ?? String(localized: "this address book"))?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let book = deleting { run { try await $0.delete(book) } }
                deleting = nil
            }
        } message: {
            Text("Every contact in it is deleted from the server too, as soon as this Mac is online.")
        }
    }

    @ViewBuilder
    private func row(_ book: AddressBookRecord) -> some View {
        let isOwn = book.sharedBy == nil
        let isRecent = ContactsListing.isRecentlyContacted(book)
        HStack(spacing: theme.metrics.spacing.standard) {
            Toggle(
                isOn: Binding(
                    get: { book.isEnabled },
                    set: { value in run { try await $0.setEnabled(value, book: book) } })
            ) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(book.isEnabled ? String(localized: "Shown in Contacts") : String(localized: "Hidden from Contacts"))
            VStack(alignment: .leading) {
                if renaming != nil, renaming == book.id {
                    TextField(String(localized: "Name"), text: $renameText)
                        .onSubmit { commitRename(book) }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(book.displayName ?? String(localized: "Address book"))
                }
                Text(subtitle(book)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename") {
                    renameText = book.displayName ?? ""
                    renaming = book.id
                }
                .disabled(!isOwn || isRecent)
                Button("Share…") { sharing = SharedBook(book: book) }
                    .disabled(!isOwn || isRecent)
                Button("Export…") { prepareExport(book) }
                Button("Copy CardDAV URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(book.url, forType: .string)
                    status = String(localized: "CardDAV URL copied.")
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = book }
                    .disabled(!isOwn || isRecent)
            } label: {
                MailSymbol.more.view(size: .small, label: .text("Actions for this address book"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }

    private func subtitle(_ book: AddressBookRecord) -> String {
        let count = book.id.map { id in browser.login(sessionId).entries.count { $0.record.addressBookId == id } }
        var parts: [String] = []
        if let owner = book.sharedBy {
            let name = owner.split(separator: "/").last.map(String.init) ?? owner
            parts.append(String(localized: "Shared by \(name)"))
        }
        if book.isReadOnly { parts.append(String(localized: "Read-only")) }
        if book.isEnabled, let count { parts.append(String(localized: "\(count) contacts")) }
        if !book.isEnabled { parts.append(String(localized: "Hidden")) }
        return parts.joined(separator: " · ")
    }

    private func create(model: ContactsLoginModel) {
        let name = newName
        let fallback = session.accounts.first { $0.id == sessionId }.map {
            AddressBookActions.fallbackHome(serverURL: $0.server, userId: $0.loginName)
        }
        run { actions in
            try await actions.create(name: name, books: model.books, fallbackHome: fallback)
            newName = ""
        }
    }

    private func commitRename(_ book: AddressBookRecord) {
        let name = renameText
        renaming = nil
        run { try await $0.rename(book, to: name) }
    }

    /// Reads every card of the book from the mirror — disabled books included, which the
    /// login model does not parse — then opens the save panel.
    private func prepareExport(_ book: AddressBookRecord) {
        guard let id = book.id else { return }
        let store = browser.store
        Task {
            do {
                let records = try await store.contacts(addressBookId: id)
                let data = await Task.detached(priority: .userInitiated) { VCardExport.data(records) }.value
                export = VCardFile(data: data, name: VCardExport.fileName(book.displayName))
            } catch {
                ContactsBrowser.logger.error(
                    "address book export read failed: \(String(describing: type(of: error)), privacy: .public)")
                status = String(localized: "The address book could not be exported.")
            }
        }
    }

    private func run(_ work: @escaping (AddressBookActions) async throws -> Void) {
        Task {
            guard let actions = browser.actions(sessionId: sessionId) else {
                status = AddressBookActions.message(for: AddressBookActions.Failure.noQueue)
                return
            }
            do {
                try await work(AddressBookActions(actions))
                status = nil
            } catch {
                status = AddressBookActions.message(for: error)
            }
        }
    }
}

/// A `.vcf` for `fileExporter`.
nonisolated struct VCardFile: FileDocument {
    static let readableContentTypes: [UTType] = [.vCard]
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.filename ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension AddressBookActions {
    /// The sentence a refused write shows.
    static func message(for error: any Error) -> String {
        switch error {
        case Failure.noQueue, ContactsActions.Failure.noQueue:
            String(localized: "Sign in to this account to edit contacts.")
        case Failure.readOnly, ContactsActions.Failure.readOnly:
            String(localized: "This address book is read-only.")
        case Failure.notOwner:
            String(localized: "Only the owner of a shared address book can change it.")
        case Failure.noHome:
            String(localized: "There is no address book home to create it in.")
        case Failure.emptyName:
            String(localized: "Enter a name.")
        default:
            {
                ContactsBrowser.logger.error(
                    "address book write not queued: \(String(describing: type(of: error)), privacy: .public)")
                return String(localized: "The change could not be saved.")
            }()
        }
    }
}

/// The book the share sheet is open for; the record has no `Identifiable` of its own.
private struct SharedBook: Identifiable {
    let book: AddressBookRecord
    var id: String { book.url }
}
