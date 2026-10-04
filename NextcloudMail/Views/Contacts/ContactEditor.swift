// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// Edit mode: every typed vCard property as a field, groups as chips, the rest read-only
/// ([ux-spec.md](../../../docs/product/ux-spec.md#contacts-ws-35)). Saving hands the draft
/// back; the caller queues it.
struct ContactEditor: View {
    @Binding var draft: ContactDraft
    /// Every group of the login, for the "Add to group" menu.
    let groups: [String]
    let title: String
    var bookPicker: AnyView?
    let onCancel: () -> Void
    let onSave: (ContactDraft) -> Void

    @Environment(\.ncTheme) private var theme
    @State private var newGroup = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let bookPicker { Section { bookPicker } }
                Section("Name") {
                    TextField("Display name", text: $draft.formattedName, prompt: Text(draft.effectiveFormattedName))
                    TextField("Prefix", text: $draft.prefix)
                    TextField("First name", text: $draft.given)
                    TextField("Additional names", text: $draft.additional)
                    TextField("Last name", text: $draft.family)
                    TextField("Suffix", text: $draft.suffix)
                    TextField("Nickname", text: $draft.nickname)
                }
                Section("Work") {
                    TextField("Organization", text: $draft.organization)
                    TextField("Department", text: $draft.department)
                    TextField("Title", text: $draft.title)
                }
                ForEach(ContactDraft.Kind.allCases, id: \.self) { kind in
                    Section(kind.title) {
                        ForEach($draft.fields) { $field in
                            if field.kind == kind { fieldRow($field) }
                        }
                        Button("Add \(kind.title.lowercased())") {
                            draft.fields.append(
                                ContactDraft.Field(
                                    kind: kind, type: kind.typeChoices.first ?? "", value: "",
                                    address: kind == .address ? Array(repeating: "", count: 7) : []))
                        }
                    }
                }
                Section("Dates") {
                    TextField("Birthday", text: $draft.birthday, prompt: Text(verbatim: "YYYY-MM-DD"))
                    TextField("Anniversary", text: $draft.anniversary, prompt: Text(verbatim: "YYYY-MM-DD"))
                }
                Section("Groups") {
                    if !draft.categories.isEmpty {
                        ContactChipFlow(items: draft.categories) { name in
                            NCChip(name, onRemove: { draft.categories.removeAll { $0 == name } })
                        }
                    }
                    HStack {
                        TextField("New group", text: $newGroup)
                            .onSubmit(addGroup)
                        Button("Add", action: addGroup)
                            .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                        let others = groups.filter { !draft.categories.contains($0) }
                        if !others.isEmpty {
                            Menu("Existing group") {
                                ForEach(others, id: \.self) { name in
                                    Button(name) { draft.categories.append(name) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                Section("Notes") {
                    TextEditor(text: $draft.note)
                        .frame(minHeight: Self.noteHeight)
                        .accessibilityLabel(Text("Notes"))
                }
                Section {
                    ContactOtherPropertiesView(properties: draft.otherProperties)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primary)
                    .disabled(!draft.hasChanges)
            }
            .padding(theme.metrics.spacing.standard)
        }
    }

    private func addGroup() {
        let name = newGroup.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !draft.categories.contains(name) { draft.categories.append(name) }
        newGroup = ""
    }

    @ViewBuilder
    private func fieldRow(_ field: Binding<ContactDraft.Field>) -> some View {
        let kind = field.wrappedValue.kind
        HStack(alignment: .firstTextBaseline) {
            Picker("Type", selection: field.type) {
                ForEach(typeChoices(field.wrappedValue), id: \.self) { type in
                    Text(ContactDraft.Kind.typeLabel(type)).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()
            if kind == .address {
                VStack {
                    ForEach(Array(Self.addressParts.enumerated()), id: \.offset) { index, label in
                        TextField(label, text: addressBinding(field, index))
                    }
                }
            } else {
                TextField(kind.title, text: field.value)
            }
            Button {
                draft.fields.removeAll { $0.id == field.wrappedValue.id }
            } label: {
                MailSymbol.remove.view(size: .small, label: .text("Remove"))
            }
            .buttonStyle(.borderless)
        }
    }

    /// The kind's choices, plus whatever type the card already had.
    private func typeChoices(_ field: ContactDraft.Field) -> [String] {
        var choices = field.kind.typeChoices
        if field.type.isEmpty {
            choices.insert("", at: 0)
        } else if !choices.contains(field.type) {
            choices.insert(field.type, at: 0)
        }
        return choices
    }

    private func addressBinding(_ field: Binding<ContactDraft.Field>, _ index: Int) -> Binding<String> {
        Binding(
            get: { index < field.wrappedValue.address.count ? field.wrappedValue.address[index] : "" },
            set: { value in
                var parts = field.wrappedValue.address
                if parts.count < 7 { parts += Array(repeating: "", count: 7 - parts.count) }
                parts[index] = value
                field.wrappedValue.address = parts
            })
    }

    private static let addressParts = [
        String(localized: "Post office box"), String(localized: "Address line 2"), String(localized: "Street"),
        String(localized: "City"), String(localized: "State or region"), String(localized: "Postal code"),
        String(localized: "Country"),
    ]

    private static let noteHeight = 80.0
}

/// New contact: an empty editor in the detail pane, the book picker on top; nothing is
/// written until Save, which queues a `contactPut` and selects the new row.
struct ContactNewEditor: View {
    let request: ContactsBrowser.NewContactRequest

    @Environment(ContactsBrowser.self) private var browser
    @State private var draft: ContactDraft
    @State private var bookId: Int64?

    init(request: ContactsBrowser.NewContactRequest) {
        self.request = request
        var categories: [String] = []
        if case .group(let name) = request.scope { categories = [name] }
        _draft = State(initialValue: ContactDraft.new(uid: UUID().uuidString, categories: categories))
    }

    var body: some View {
        let login = browser.login(request.sessionId)
        let writable = login.books.filter {
            $0.isEnabled && !$0.isReadOnly && !ContactsListing.isRecentlyContacted($0)
        }
        ContactEditor(
            draft: $draft,
            groups: login.groups.map(\.name),
            title: String(localized: "New contact"),
            bookPicker: AnyView(
                Picker("Address book", selection: $bookId) {
                    ForEach(writable, id: \.id) { book in
                        Text(book.displayName ?? book.url).tag(book.id)
                    }
                }),
            onCancel: { browser.endNewContact(created: nil) },
            onSave: { draft in save(draft, login: login) }
        )
        .task {
            if bookId == nil {
                bookId = ContactsActions.defaultBook(for: request.scope, books: login.books)?.id
            }
        }
    }

    /// Created from the Favorites list, the new contact is starred too — as a group list's
    /// new contact joins the group.
    private func save(_ draft: ContactDraft, login: ContactsLoginModel) {
        guard let book = login.books.first(where: { $0.id == bookId }) else { return }
        let starred = request.scope == .favorites
        Task {
            var created: Int64?
            await browser.perform(sessionId: request.sessionId) { actions, _ in
                created = try await actions.create(draft, in: book)
                if starred, let id = created, let record = try await actions.store.contact(id: id) {
                    try await actions.setFavorite(true, contact: record, in: book)
                }
            }
            browser.endNewContact(created: created)
        }
    }
}
