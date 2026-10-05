// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// The Contacts section's shared state: one ``ContactsLoginModel`` per login, read by the
/// sidebar section, the list and the detail pane, and the list's selection.
///
/// **Hand-off API (WS-36 batch operations, WS-37 Teams).** `RootSplitView` puts one browser
/// in the environment (`@Environment(ContactsBrowser.self)`):
/// - ``selection`` — the selected `contact.id`s; more than one shows
///   `ContactsMultiSelectionView` in the detail column, whose marked slot is WS-36's.
/// - ``selectedContacts(sessionId:)`` — those rows, in list order.
/// - ``login(_:)`` — books, parsed entries and groups of one login.
/// - ``actions(sessionId:)`` — the queued writes (save, create, delete, favourite).
/// - ``reveal(_:)`` — select one contact (after a merge or an import, say).
@MainActor
@Observable
final class ContactsBrowser {
    /// Selected `contact.id`s in the list. Cleared when the sidebar scope changes.
    var selection: Set<Int64> = []
    /// The list's search field; ``searchMatches`` is its FTS answer, nil when not searching.
    var searchText = ""
    private(set) var searchMatches: Set<Int64>?
    /// A new contact being written in the detail pane, not saved yet.
    private(set) var newContact: NewContactRequest?
    /// Cards waiting for the delete confirmation.
    var pendingDelete: [ContactRecord] = []
    /// The last write that could not be queued, for the list's alert.
    var failure: String?

    let store: MailStore
    private let queue: @MainActor (String) -> MutationQueue?
    // Not observed: filled lazily from view bodies, and a view must not invalidate itself.
    @ObservationIgnored private var logins: [String: ContactsLoginModel] = [:]

    struct NewContactRequest: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let scope: ContactsScope
    }

    init(store: MailStore, queue: @escaping @MainActor (String) -> MutationQueue?) {
        self.store = store
        self.queue = queue
    }

    /// The per-login model, created and started on first use.
    func login(_ sessionId: String) -> ContactsLoginModel {
        if let existing = logins[sessionId] { return existing }
        let model = ContactsLoginModel(sessionId: sessionId, store: store)
        logins[sessionId] = model
        model.start()
        return model
    }

    /// The queued writes for one login, or nil while its engine is not running (signed out).
    func actions(sessionId: String) -> ContactsActions? {
        let model = login(sessionId)
        guard let loginId = model.loginId else { return nil }
        return ContactsActions(loginId: loginId, store: store, queue: queue(sessionId))
    }

    func selectedContacts(sessionId: String) -> [ContactRecord] {
        login(sessionId).entries.filter { selection.contains($0.id) }.map(\.record)
    }

    /// What the detail column shows for one login: the new-contact editor, the batch pane for
    /// more than one selected card, the one selected card, or nothing.
    func detailPane(sessionId: String) -> ContactsDetailPane {
        if let newContact, newContact.sessionId == sessionId { return .newContact(newContact) }
        if selection.count > 1 { return .batch(count: selection.count) }
        if let id = selection.first { return .contact(id) }
        return .nothing
    }

    func reveal(_ contactId: Int64) {
        newContact = nil
        selection = [contactId]
    }

    /// New contact: the detail pane opens an empty editor; nothing is written until Save.
    func beginNewContact(sessionId: String, scope: ContactsScope) {
        selection = []
        newContact = NewContactRequest(sessionId: sessionId, scope: scope)
    }

    func endNewContact(created: Int64?) {
        newContact = nil
        if let created { selection = [created] }
    }

    func requestDelete(_ records: [ContactRecord]) {
        pendingDelete = records
    }

    func confirmDelete(sessionId: String) async {
        let records = pendingDelete
        pendingDelete = []
        let ids = Set(records.compactMap(\.id))
        await perform(sessionId: sessionId) { actions, model in
            try await actions.delete(records, books: model.books)
        }
        selection.subtract(ids)
    }

    func toggleFavorite(_ record: ContactRecord, sessionId: String) {
        Task {
            await perform(sessionId: sessionId) { actions, model in
                guard let book = model.book(id: record.addressBookId) else { throw ContactsActions.Failure.readOnly }
                try await actions.setFavorite(!record.isFavorite, contact: record, in: book)
            }
        }
    }

    /// Runs one queued write, turning a refusal into ``failure``'s sentence.
    func perform(
        sessionId: String, _ work: (ContactsActions, ContactsLoginModel) async throws -> Void
    ) async {
        guard let actions = actions(sessionId: sessionId) else {
            failure = String(localized: "Sign in to this account to edit contacts.")
            return
        }
        do {
            try await work(actions, login(sessionId))
        } catch ContactsActions.Failure.noQueue {
            failure = String(localized: "Sign in to this account to edit contacts.")
        } catch ContactsActions.Failure.readOnly {
            failure = String(localized: "This address book is read-only.")
        } catch ContactsActions.Failure.noUID {
            failure = String(localized: "This contact has no UID, which the server needs for this.")
        } catch {
            Self.logger.error("contact write not queued: \(String(describing: type(of: error)), privacy: .public)")
            failure = String(localized: "The contact could not be saved.")
        }
    }

    /// Runs the list's search through `contactSearch` (FTS5, prefix per word), every enabled
    /// book of the login. Empty text ends the search.
    func search(_ text: String, sessionId: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let loginId = login(sessionId).loginId else {
            searchMatches = nil
            return
        }
        do {
            // One row per address; the limit only has to exceed any real address count.
            let rows = try await store.contactSuggestions(matching: trimmed, loginId: loginId, limit: 50_000)
            guard !Task.isCancelled else { return }
            searchMatches = Set(rows.map(\.contactId))
        } catch {
            Self.logger.error("contact search failed: \(String(describing: type(of: error)), privacy: .public)")
            searchMatches = []
        }
    }

    nonisolated static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "contacts")
}

/// The Contacts detail column's content, resolved by ``ContactsBrowser/detailPane(sessionId:)``.
enum ContactsDetailPane: Equatable {
    case newContact(ContactsBrowser.NewContactRequest)
    case batch(count: Int)
    case contact(Int64)
    case nothing
}

/// One login's books, cards and groups, live from the mirror.
@MainActor
@Observable
final class ContactsLoginModel {
    let sessionId: String
    private(set) var loginId: Int64?
    /// The login's mail accounts; the first sends "New message" to a contact.
    private(set) var accountIds: [Int64] = []
    /// Every book of the login, enabled or not, in the server's order.
    private(set) var books: [AddressBookRecord] = []
    /// Every card of the login's enabled books, parsed.
    private(set) var entries: [ContactEntry] = []
    private(set) var groups: [ContactGroupSummary] = []
    private(set) var hasLoaded = false

    private let store: MailStore
    private var task: Task<Void, Never>?

    init(sessionId: String, store: MailStore) {
        self.sessionId = sessionId
        self.store = store
    }

    var recentBookIds: Set<Int64> {
        Set(books.filter(ContactsListing.isRecentlyContacted).compactMap(\.id))
    }

    func book(id: Int64) -> AddressBookRecord? { books.first { $0.id == id } }

    func entry(id: Int64) -> ContactEntry? { entries.first { $0.id == id } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, store, sessionId] in
            guard let login = await PeopleLogin.resolve(store: store, sessionId: sessionId) else {
                self?.hasLoaded = true
                return
            }
            self?.loginId = login.loginId
            self?.accountIds = login.accountIds
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.observeBooks(loginId: login.loginId) }
                group.addTask { await self?.observeCards(loginId: login.loginId) }
            }
        }
    }

    private func observeBooks(loginId: Int64) async {
        do {
            for try await books in store.observeAddressBooks(loginId: loginId) {
                self.books = books
            }
        } catch {
            ContactsBrowser.logger.error(
                "address books observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func observeCards(loginId: Int64) async {
        do {
            for try await records in store.observeContacts(loginId: loginId) {
                let previous = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let started = ContinuousClock.now
                // Parsing is the cost (a vCard per card); off the main actor, and only for
                // cards whose text changed since the last answer.
                let parsed = await Task.detached(priority: .userInitiated) {
                    let entries = records.compactMap { record -> ContactEntry? in
                        if let id = record.id, var reused = previous[id], reused.record.vcard == record.vcard {
                            reused.record = record
                            return reused
                        }
                        return ContactEntry(record: record)
                    }
                    return (entries, ContactsListing.groups(entries))
                }.value
                entries = parsed.0
                groups = parsed.1
                hasLoaded = true
                let elapsed = ContinuousClock.now - started
                ContactsBrowser.logger.debug(
                    "contacts: \(records.count, privacy: .public) cards parsed in \(elapsed, privacy: .public)")
            }
        } catch {
            ContactsBrowser.logger.error(
                "contacts observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
