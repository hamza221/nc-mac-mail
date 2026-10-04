// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailCore
import NCMailStore
import NextcloudUI
import Observation
import SwiftUI

/// The detail column for a Contacts selection: the new-contact editor, the multi-selection
/// pane, one contact, or nothing ([ux-spec.md](../../../docs/product/ux-spec.md#contacts-ws-35)).
struct ContactsDetailColumn: View {
    let sessionId: String
    let scope: ContactsScope

    @Environment(ContactsBrowser.self) private var browser

    var body: some View {
        if let request = browser.newContact, request.sessionId == sessionId {
            ContactNewEditor(request: request).id(request.id)
        } else if browser.selection.count > 1 {
            ContactsMultiSelectionView(sessionId: sessionId)
        } else if let id = browser.selection.first {
            ContactDetailView(contactId: id, sessionId: sessionId).id(id)
        } else {
            ContentUnavailableView {
                Label {
                    Text("No contact selected")
                } icon: {
                    MailSymbol.account.view(size: .large, label: .decorative)
                }
            }
        }
    }
}

/// More than one contact selected: how many, and the batch actions.
struct ContactsMultiSelectionView: View {
    let sessionId: String

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(spacing: theme.metrics.spacing.standard) {
            MailSymbol.allContacts.view(size: .large, label: .decorative)
            Text("\(browser.selection.count) contacts selected").font(.title3)
            ContactBatchActions(sessionId: sessionId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One contact, live from the mirror: the card while viewing, the editor while editing.
@MainActor
@Observable
final class ContactDetailModel {
    let contactId: Int64
    private(set) var record: ContactRecord?
    private(set) var card: VCard?
    private(set) var hasLoaded = false
    private let store: MailStore

    init(contactId: Int64, store: MailStore) {
        self.contactId = contactId
        self.store = store
    }

    func run() async {
        do {
            for try await record in store.observeContact(id: contactId) {
                self.record = record
                card = record.flatMap { try? VCardParser.parse($0.vcard).first }
                hasLoaded = true
            }
        } catch {
            ContactsBrowser.logger.error(
                "contact observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

struct ContactDetailView: View {
    let contactId: Int64
    let sessionId: String

    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser

    var body: some View {
        ContactDetailContent(
            model: ContactDetailModel(contactId: contactId, store: session.store),
            login: browser.login(sessionId))
    }
}

private struct ContactDetailContent: View {
    @State private var model: ContactDetailModel
    let login: ContactsLoginModel

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.ncTheme) private var theme
    @State private var draft: ContactDraft?
    @State private var cropping: CroppingImage?
    @State private var showsFullSize = false

    init(model: ContactDetailModel, login: ContactsLoginModel) {
        _model = State(initialValue: model)
        self.login = login
    }

    var body: some View {
        Group {
            if let record = model.record, let card = model.card {
                if draft != nil {
                    ContactEditor(
                        draft: Binding(get: { draft ?? ContactDraft(card: card) }, set: { draft = $0 }),
                        groups: login.groups.map(\.name),
                        title: String(localized: "Edit contact"),
                        onCancel: { draft = nil },
                        onSave: { edited in save(edited, record: record) })
                } else {
                    ContactCardView(
                        record: record, card: card, book: login.book(id: record.addressBookId), login: login,
                        onEdit: { draft = ContactDraft(card: card) },
                        onPhoto: { photoAction($0, record: record, card: card) })
                }
            } else if model.hasLoaded {
                ContentUnavailableView {
                    Label {
                        Text("This contact is no longer here")
                    } icon: {
                        MailSymbol.account.view(size: .large, label: .decorative)
                    }
                }
            }
        }
        .task { await model.run() }
        .sheet(item: $cropping) { item in
            ContactPhotoCropSheet(image: item.image) { data in
                cropping = nil
                guard let data, let record = model.record, let card = model.card else { return }
                var change = ContactDraft(card: card)
                change.photo = .set(data, subtype: "jpeg")
                save(change, record: record)
            }
        }
        .sheet(isPresented: $showsFullSize) {
            if let data = model.card?.photo?.data, let image = NSImage(data: data) {
                ContactPhotoFullSizeSheet(
                    image: image, onDownload: { download() }, onClose: { showsFullSize = false })
            }
        }
    }

    private func save(_ edited: ContactDraft, record: ContactRecord) {
        guard let book = login.book(id: record.addressBookId) else { return }
        Task {
            await browser.perform(sessionId: login.sessionId) { actions, _ in
                try await actions.save(edited, over: record, in: book)
            }
            draft = nil
        }
    }

    private func photoAction(_ action: ContactPhotoAction, record: ContactRecord, card: VCard) {
        switch action {
        case .upload:
            guard let data = ContactPhotoTools.chooseImage(), let image = ContactPhotoTools.cgImage(data) else {
                return
            }
            cropping = CroppingImage(image: image)
        case .remove:
            var change = ContactDraft(card: card)
            change.photo = .removed
            save(change, record: record)
        case .fullSize:
            showsFullSize = true
        case .download:
            download()
        case .social(let network):
            guard let book = login.book(id: record.addressBookId) else { return }
            Task {
                await browser.perform(sessionId: login.sessionId) { actions, _ in
                    try await actions.fetchSocialAvatar(network: network, contact: record, in: book)
                }
            }
        }
    }

    private func download() {
        guard let photo = model.card?.photo, let data = photo.data else { return }
        let name = model.card?.formattedName ?? String(localized: "Contact")
        ContactPhotoTools.save(data, suggestedName: "\(name).\(ContactPhotoTools.fileExtension(photo))")
    }
}

private struct CroppingImage: Identifiable {
    let id = UUID()
    let image: CGImage
}

enum ContactPhotoAction: Hashable {
    case upload
    case remove
    case fullSize
    case download
    case social(String)
}

/// View mode: the profile card, every property, groups, the rest read-only, recent mail.
private struct ContactCardView: View {
    let record: ContactRecord
    let card: VCard
    let book: AddressBookRecord?
    let login: ContactsLoginModel
    let onEdit: () -> Void
    let onPhoto: (ContactPhotoAction) -> Void

    @Environment(AppSession.self) private var session
    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.ncTheme) private var theme
    @Environment(\.openComposer) private var openComposer

    private var readOnlyReason: String? { ContactsActions.readOnlyReason(book) }
    private var canEdit: Bool { readOnlyReason == nil }
    private var email: String? { card.emails.first(where: \.isPreferred)?.value ?? card.emails.first?.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.loose) {
                NCProfileCard(
                    displayName: displayName,
                    user: email,
                    secondaryLines: [
                        [card.title, card.organization.first].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        card.nicknames.joined(separator: ", "),
                        book?.displayName ?? "",
                    ],
                    load: photoLoader
                ) {
                    actions
                }
                if let readOnlyReason {
                    Label {
                        Text(readOnlyReason)
                    } icon: {
                        MailSymbol.encrypted.view(size: .small, label: .decorative)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                ContactPropertiesView(card: card)
                if !card.categories.isEmpty {
                    section(String(localized: "Groups")) {
                        ContactChipFlow(items: card.categories) { NCChip($0) }
                    }
                }
                if let note = card.note, !note.isEmpty {
                    section(String(localized: "Notes")) { Text(verbatim: note).textSelection(.enabled) }
                }
                ContactOtherPropertiesView(properties: ContactDraft(card: card).otherProperties)
                if let email {
                    section(String(localized: "Recent mail")) {
                        RecentMailList(email: email, sessionId: login.sessionId, limit: 10)
                    }
                }
                ContactTeamsExtras(record: record, book: book, login: login)
            }
            .padding(theme.metrics.spacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayName: String {
        let name = card.formattedName ?? record.displayName ?? ""
        return name.isEmpty ? String(localized: "No name") : name
    }

    /// The card's own PHOTO when inline; a URI photo is not fetched by a view, so the mirror's
    /// avatar for the address stands in.
    private var photoLoader: (@Sendable () async throws -> Image)? {
        if let data = card.photo?.data {
            return {
                guard let image = NSImage(data: data) else { throw AvatarUnavailable.undecodable }
                return Image(nsImage: image)
            }
        }
        return session.store.avatarLoader(for: email)
    }

    private var actions: some View {
        HStack(spacing: theme.metrics.spacing.tight) {
            if let email {
                Button("New message") {
                    openComposer(
                        .new(accountId: login.accountIds.first, mailto: ContactCardContentLinks.mailto(email)))
                }
                .buttonStyle(.primary)
            }
            Button {
                browser.toggleFavorite(record, sessionId: login.sessionId)
            } label: {
                (record.isFavorite ? MailSymbol.star : MailSymbol.favoriteOff)
                    .view(
                        size: .small,
                        label: .text(record.isFavorite ? "Remove from favorites" : "Add to favorites"))
            }
            .buttonStyle(.secondary)
            .disabled(!canEdit)
            .help(
                record.isFavorite ? String(localized: "Remove from favorites") : String(localized: "Add to favorites"))
            Button("Edit", action: onEdit)
                .buttonStyle(.secondary)
                .disabled(!canEdit)
                .help(readOnlyReason ?? String(localized: "Edit this contact"))
            Menu {
                photoMenu
                Divider()
                Button("Delete contact", role: .destructive) { browser.requestDelete([record]) }
                    .disabled(!canEdit)
            } label: {
                MailSymbol.more.view(size: .small, label: .text("More actions"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var photoMenu: some View {
        let photo = card.photo
        Button("Upload picture…") { onPhoto(.upload) }.disabled(!canEdit)
        if photo?.data != nil {
            Button("Show full size") { onPhoto(.fullSize) }
            Button("Download picture…") { onPhoto(.download) }
        }
        if photo != nil {
            Button("Remove picture") { onPhoto(.remove) }.disabled(!canEdit)
        }
        let networks = ContactsActions.socialNetworks(for: card)
        if !networks.isEmpty {
            Menu("Get picture from") {
                ForEach(networks, id: \.self) { network in
                    Button(network.capitalized) { onPhoto(.social(network)) }
                }
            }
            .disabled(!canEdit || card.uid == nil)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// Every typed property, one labelled row each, with the actions a value invites.
struct ContactPropertiesView: View {
    let card: VCard

    @Environment(\.ncTheme) private var theme

    var body: some View {
        Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: theme.metrics.spacing.standard,
            verticalSpacing: theme.metrics.spacing.tight
        ) {
            if let name = card.name {
                let parts = [name.prefixes, name.given, name.additional, name.family, name.suffixes]
                    .filter { !$0.isEmpty }
                if !parts.isEmpty { row(String(localized: "Name"), parts.joined(separator: " ")) }
            }
            if !card.nicknames.isEmpty { row(String(localized: "Nickname"), card.nicknames.joined(separator: ", ")) }
            if !card.organization.isEmpty {
                row(String(localized: "Organization"), card.organization.joined(separator: " · "))
            }
            if let title = card.title, !title.isEmpty { row(String(localized: "Title"), title) }
            ForEach(Array(card.emails.enumerated()), id: \.offset) { _, value in
                row(label(.email, value.types), value.value, link: ContactCardContentLinks.mailto(value.value))
            }
            ForEach(Array(card.phones.enumerated()), id: \.offset) { _, value in
                row(label(.phone, value.types), value.value, link: Self.tel(value.value))
            }
            ForEach(Array(card.addresses.enumerated()), id: \.offset) { _, address in
                row(label(.address, address.types), Self.format(address))
            }
            ForEach(Array(card.urls.enumerated()), id: \.offset) { _, value in
                row(label(.url, value.types), value.value, link: URL(string: value.value))
            }
            ForEach(Array(card.impps.enumerated()), id: \.offset) { _, value in
                row(label(.impp, value.types), value.value)
            }
            ForEach(Array(card.socialProfiles.enumerated()), id: \.offset) { _, value in
                row(
                    label(.social, value.types), value.value,
                    link: URL(string: value.value).flatMap { $0.scheme == nil ? nil : $0 })
            }
            ForEach(Array(card.related.enumerated()), id: \.offset) { _, value in
                row(label(.related, value.types), value.value)
            }
            if let birthday = card.birthday { row(String(localized: "Birthday"), Self.format(birthday)) }
            if let anniversary = card.anniversary { row(String(localized: "Anniversary"), Self.format(anniversary)) }
        }
    }

    private func label(_ kind: ContactDraft.Kind, _ types: [String]) -> String {
        let type = types.first {
            $0.caseInsensitiveCompare("PREF") != .orderedSame && $0.caseInsensitiveCompare("INTERNET") != .orderedSame
        }
        return type.map { "\(kind.title) · \(ContactDraft.Kind.typeLabel($0))" } ?? kind.title
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, link: URL? = nil) -> some View {
        GridRow {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            if let link {
                Link(value, destination: link)
            } else {
                Text(verbatim: value).textSelection(.enabled)
            }
        }
    }

    static func tel(_ number: String) -> URL? {
        URL(string: "tel:" + number.filter { $0.isNumber || $0 == "+" })
    }

    static func format(_ address: VCardAddress) -> String {
        [
            address.postOfficeBox, address.extended, address.street,
            [address.postalCode, address.locality].filter { !$0.isEmpty }.joined(separator: " "),
            address.region, address.country,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A date as the user's locale writes it; a year-less `--MMDD` without a year.
    static func format(_ date: VCardDate) -> String {
        guard let month = date.month, let day = date.day else { return date.raw }
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian), year: date.year ?? 2000, month: month, day: day)
        guard let value = components.date else { return date.raw }
        if date.year == nil {
            return value.formatted(.dateTime.month(.wide).day())
        }
        return value.formatted(date: .long, time: .omitted)
    }
}

/// "Other properties": every line the editor does not own, shown as written and never
/// edited, so another client's data passes through an edit untouched.
struct ContactOtherPropertiesView: View {
    let properties: [DirectoryProperty]

    @Environment(\.ncTheme) private var theme

    var body: some View {
        if !properties.isEmpty {
            DisclosureGroup {
                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: theme.metrics.spacing.standard,
                    verticalSpacing: theme.metrics.spacing.hairline
                ) {
                    ForEach(Array(properties.enumerated()), id: \.offset) { _, property in
                        GridRow {
                            Text(verbatim: property.name).foregroundStyle(.secondary)
                            Text(verbatim: property.decodedValue())
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            } label: {
                Text("Other properties (\(properties.count))").font(.headline)
            }
            .help(String(localized: "Properties written by other apps. They are kept as they are when you edit."))
        }
    }
}

/// Chips that wrap onto as many lines as they need.
struct ContactChipFlow<Chip: View>: View {
    let items: [String]
    let chip: (String) -> Chip

    @Environment(\.ncTheme) private var theme

    var body: some View {
        ContactFlowLayout(spacing: theme.metrics.spacing.tight) {
            ForEach(items, id: \.self) { chip($0) }
        }
    }
}

/// Left-to-right wrapping layout for chips.
struct ContactFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
