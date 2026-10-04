// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// Everything the contact card shows and does, read from the mirror (§5.11, WS-26).
@MainActor
@Observable
final class ContactCardModel {
    let email: String
    let label: String?
    let accountId: Int64?

    private(set) var login: PeopleLogin?
    /// Contacts of the login's enabled books carrying the address, live.
    private(set) var contacts: [ContactRecord] = []
    private(set) var books: [AddressBookRecord] = []
    /// "Add to contact" candidates for the current search text: people, in writable books.
    private(set) var searchResults: [ContactSuggestionRow] = []
    /// One line of feedback after a write, or why it could not be made.
    private(set) var notice: Notice?
    private(set) var isWorking = false

    enum Notice: Equatable {
        case added(name: String)
        case created(name: String)
        case alreadyThere
        case failed
        case signedOut
    }

    private let store: MailStore
    private let queue: @MainActor (String) -> MutationQueue?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "people")

    init(
        email: String, label: String?, accountId: Int64?, store: MailStore,
        queue: @escaping @MainActor (String) -> MutationQueue?
    ) {
        self.email = email
        self.label = label
        self.accountId = accountId
        self.store = store
        self.queue = queue
    }

    /// The matched contact the card describes: a person before a group, by name.
    var contact: ContactRecord? { contacts.first { !$0.isGroup } ?? contacts.first }

    var displayName: String {
        if let name = contact?.displayName, !name.isEmpty { return name }
        if let label, !label.isEmpty { return label }
        return email
    }

    var bookName: String? {
        guard let contact else { return nil }
        return books.first { $0.id == contact.addressBookId }?.displayName
    }

    /// The books a new card can go into: enabled and writable, the login's own first.
    var writableBooks: [AddressBookRecord] {
        books.filter { $0.isEnabled && !$0.isReadOnly }
            .sorted { lhs, rhs in
                if (lhs.sharedBy == nil) != (rhs.sharedBy == nil) { return lhs.sharedBy == nil }
                return lhs.position < rhs.position
            }
    }

    /// False while the login's engine is not running: a queued write needs its drainer.
    var canWrite: Bool {
        guard let login else { return false }
        return queue(login.sessionId) != nil
    }

    // MARK: - Reads

    /// Resolves the login, then follows the contacts carrying the address until cancelled.
    func run() async {
        guard let login = await PeopleLogin.resolve(store: store, accountId: accountId) else { return }
        self.login = login
        do {
            books = try await store.addressBooks(loginId: login.loginId)
            for try await rows in store.observeContacts(withEmail: email, loginId: login.loginId) {
                contacts = rows
            }
        } catch {
            Self.logger.error("contact card observation stopped: \(String(describing: error), privacy: .public)")
        }
    }

    /// Contacts the address could be added to, for the text typed so far.
    func search(_ text: String) async {
        guard let login, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        do {
            let rows = try await store.contactSuggestions(matching: text, loginId: login.loginId, limit: 200)
            var seen = Set<Int64>()
            searchResults = rows.filter { !$0.isGroup && !$0.isReadOnlyBook && seen.insert($0.contactId).inserted }
                .sorted {
                    (RecipientRanking.contactName($0) ?? "").localizedStandardCompare(
                        RecipientRanking.contactName($1) ?? "") == .orderedAscending
                }
                .prefix(20).map { $0 }
        } catch {
            searchResults = []
        }
    }

    // MARK: - Writes

    func add(toContact row: ContactSuggestionRow) async {
        guard let login else { return }
        await perform {
            let added = try await ContactCardActions.add(
                email: email, toContact: row.contactId, loginId: login.loginId, store: store,
                queue: queue(login.sessionId))
            return added ? .added(name: RecipientRanking.contactName(row) ?? email) : .alreadyThere
        }
    }

    func create(name: String, in book: AddressBookRecord) async {
        guard let login else { return }
        await perform {
            try await ContactCardActions.create(
                name: name, email: email, in: book, loginId: login.loginId, queue: queue(login.sessionId))
            return .created(name: name.isEmpty ? email : name)
        }
    }

    private func perform(_ write: () async throws -> Notice) async {
        isWorking = true
        defer { isWorking = false }
        do {
            notice = try await write()
        } catch ContactCardActions.Failure.noQueue {
            notice = .signedOut
        } catch {
            Self.logger.error("contact card write not queued: \(String(describing: error), privacy: .public)")
            notice = .failed
        }
    }
}
