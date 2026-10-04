// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI

/// The contact card for one address (§5.11): who it is in the contacts mirror, and Reply,
/// Copy address, Add to contact, New contact
/// ([ux-spec.md](../../../docs/product/ux-spec.md#people-suggestions-bubbles-and-the-contact-card-ws-26)).
///
/// Host it in a popover: `.popover(isPresented:) { ContactCardPopover(email:label:accountId:) }`.
/// `accountId` picks the login whose contacts are searched and written; nil uses the first.
struct ContactCardPopover: View {
    let email: String
    let label: String?
    let accountId: Int64?

    @Environment(AppSession.self) private var session

    init(email: String, label: String? = nil, accountId: Int64? = nil) {
        self.email = email
        self.label = label
        self.accountId = accountId
    }

    var body: some View {
        ContactCardContent(
            model: ContactCardModel(
                email: email, label: label, accountId: accountId, store: session.store,
                queue: { [engine = session.engine] in engine.contactsQueue(sessionId: $0) }),
            avatar: session.store.avatarLoader(for: email)
        )
        // A new address is a new card: the model's observation is of one address.
        .id(email)
    }
}

private struct ContactCardContent: View {
    @State private var model: ContactCardModel
    let avatar: (@Sendable () async throws -> Image)?

    @Environment(\.ncTheme) private var theme
    @Environment(\.openComposer) private var openComposer
    @State private var mode: Mode = .card
    @State private var searchText = ""
    @State private var newName = ""
    @State private var newBookId: Int64?

    private enum Mode { case card, add, create }

    init(model: ContactCardModel, avatar: (@Sendable () async throws -> Image)?) {
        _model = State(initialValue: model)
        self.avatar = avatar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            NCProfileCard(
                displayName: model.displayName,
                user: model.email,
                secondaryLines: [model.email, contactDetail ?? ""],
                load: avatar
            ) {
                if mode == .card { actions }
            }
            switch mode {
            case .card: EmptyView()
            case .add: addToContact
            case .create: newContact
            }
            if let notice = model.notice {
                Text(noticeText(notice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.metrics.spacing.standard)
        .frame(width: Self.width)
        .task { await model.run() }
    }

    private var contactDetail: String? {
        let parts = [model.contact?.organization, model.bookName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Card actions

    private var actions: some View {
        VStack(spacing: theme.metrics.spacing.tight) {
            HStack(spacing: theme.metrics.spacing.tight) {
                Button("Reply") {
                    openComposer(.new(accountId: model.accountId, mailto: Self.mailto(model.email)))
                }
                .buttonStyle(.primary)
                Button("Copy address") { Self.copy(model.email) }
                    .buttonStyle(.secondary)
            }
            if model.contact == nil {
                HStack(spacing: theme.metrics.spacing.tight) {
                    Button("Add to contact…") { mode = .add }
                        .buttonStyle(.tertiary)
                    Button("New contact…") {
                        newName = model.label ?? ""
                        newBookId = model.writableBooks.first?.id
                        mode = .create
                    }
                    .buttonStyle(.tertiary)
                }
                .disabled(!model.canWrite || model.isWorking)
                .help(model.canWrite ? "" : String(localized: "Sign in to this account to edit contacts."))
            }
        }
    }

    /// `NSPasteboard` directly: the library's `NCPasteboard` lives in `NextcloudPlatform`,
    /// which `NextcloudUI` does not re-export and the app does not link (library feedback).
    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Add to contact

    private var addToContact: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            TextField("Search contacts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .task(id: searchText) { await model.search(searchText) }
            if model.searchResults.isEmpty {
                Text(searchText.isEmpty ? "Type a name to find the contact." : "No matching contacts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                        ForEach(model.searchResults, id: \.contactId) { row in
                            Button {
                                Task {
                                    await model.add(toContact: row)
                                    mode = .card
                                }
                            } label: {
                                NCUserBubble(displayName: RecipientRanking.contactName(row) ?? row.email ?? "")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: Self.listHeight)
            }
            Button("Cancel") { mode = .card }
                .buttonStyle(.tertiary)
        }
        .disabled(model.isWorking)
    }

    // MARK: New contact

    private var newContact: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if model.writableBooks.count > 1 {
                Picker("Address book", selection: $newBookId) {
                    ForEach(model.writableBooks, id: \.id) { book in
                        Text(verbatim: book.displayName ?? book.url).tag(book.id)
                    }
                }
            }
            HStack(spacing: theme.metrics.spacing.tight) {
                Button("Create") {
                    guard
                        let book = model.writableBooks.first(where: { $0.id == newBookId }) ?? model.writableBooks.first
                    else { return }
                    Task {
                        await model.create(name: newName, in: book)
                        mode = .card
                    }
                }
                .buttonStyle(.primary)
                .disabled(model.writableBooks.isEmpty)
                Button("Cancel") { mode = .card }
                    .buttonStyle(.tertiary)
            }
            if model.writableBooks.isEmpty {
                Text("No address book of this account can be written to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.isWorking)
    }

    // MARK: Text

    private func noticeText(_ notice: ContactCardModel.Notice) -> String {
        switch notice {
        case .added(let name): String(localized: "Added to \(name).")
        case .created(let name): String(localized: "Created \(name).")
        case .alreadyThere: String(localized: "That contact already has this address.")
        case .failed: String(localized: "The contact could not be saved.")
        case .signedOut: String(localized: "Sign in to this account to edit contacts.")
        }
    }

    static func mailto(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }

    /// Popover chrome rather than a spacing token, like the Get info sheet's width.
    private static let width = 320.0
    private static let listHeight = 180.0
}
