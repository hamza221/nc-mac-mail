// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// Every write the Contacts views make, as queued operations (ADR-0069, ADR-0081, ADR-0092).
/// No HTTP here: the queue applies each one to the mirror in the same transaction and the
/// drainer sends it when there is a network, so all of these work offline.
@MainActor
struct ContactsActions {
    enum Failure: Error, Equatable {
        /// The login's engine is not running: signed out, or not started yet.
        case noQueue
        case readOnly
        /// The card has no `UID`, which the social-avatar route names a card by.
        case noUID
    }

    let loginId: Int64
    let store: MailStore
    let queue: MutationQueue?

    /// Web Contacts' social networks this server's Contacts app can fetch a picture from —
    /// its `supportedNetworks` initial state, read off the dev server 2026-10-04.
    static let socialNetworks = ["instagram", "mastodon", "tumblr", "diaspora", "xing", "telegram", "gravatar"]

    /// The networks a card can fetch from, as web Contacts' `supportedSocial`: a supported
    /// network the card has an `X-SOCIALPROFILE` or `IMPP` of that type for, plus Gravatar
    /// when it has an address.
    static func socialNetworks(for card: VCard) -> [String] {
        let types = (card.socialProfiles + card.impps).flatMap(\.types).map { $0.lowercased() }
        var available = Set(types)
        if !card.emails.isEmpty { available.insert("gravatar") }
        return socialNetworks.filter(available.contains)
    }

    /// Saves an edited card over `contact`.
    func save(
        _ draft: ContactDraft, over contact: ContactRecord, in book: AddressBookRecord, now: Date = Date()
    )
        async throws
    {
        guard let queue else { throw Failure.noQueue }
        guard !book.isReadOnly else { throw Failure.readOnly }
        let payload = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: contact.addressBookId, existing: contact, card: draft.card(now: now))
        try await queue.perform(.contactPut(payload), loginId: loginId)
    }

    /// Creates a card in `book` at `<book path><UID>.vcf`, like web Contacts. Answers the
    /// new row's id, which the queue has already written locally.
    @discardableResult
    func create(_ draft: ContactDraft, in book: AddressBookRecord, now: Date = Date()) async throws -> Int64? {
        guard let queue else { throw Failure.noQueue }
        guard !book.isReadOnly else { throw Failure.readOnly }
        let card = draft.card(now: now)
        guard let bookId = book.id, let uid = card.uid,
            let href = ContactCardActions.newHref(bookURL: book.url, uid: uid)
        else { throw Failure.noUID }
        let payload = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: bookId, existing: nil, card: card, newHref: href)
        try await queue.perform(.contactPut(payload), loginId: loginId)
        return try await store.contacts(addressBookId: bookId).first { $0.href == href }?.id
    }

    /// Deletes cards, one queued `contactDelete` each so Discard restores them one by one.
    func delete(_ contacts: [ContactRecord], books: [AddressBookRecord]) async throws {
        guard let queue else { throw Failure.noQueue }
        for contact in contacts {
            guard let book = books.first(where: { $0.id == contact.addressBookId }), !book.isReadOnly else {
                throw Failure.readOnly
            }
            let payload = DAVWritePayload(
                loginId: loginId,
                addressBookId: contact.addressBookId,
                contactId: contact.id,
                href: contact.href,
                etag: contact.etag,
                before: DAVWriteSnapshot(
                    existed: true, body: contact.vcard, etag: contact.etag, isFavorite: contact.isFavorite)
            )
            try await queue.perform(.contactDelete(payload), loginId: loginId)
        }
    }

    /// Web Contacts' star: `nc:favorite` on the card, not a vCard property (ADR-0092). A
    /// PROPPATCH like any other write, so a read-only book refuses it too.
    func setFavorite(_ favorite: Bool, contact: ContactRecord, in book: AddressBookRecord) async throws {
        guard let queue else { throw Failure.noQueue }
        guard !book.isReadOnly else { throw Failure.readOnly }
        let payload = ContactWriteHandler.favoritePayload(loginId: loginId, contact: contact, favorite: favorite)
        try await queue.perform(.contactFavorite(payload), loginId: loginId)
    }

    /// Asks the server to fetch the card's picture from `network`; the rewritten PHOTO arrives
    /// with the next contacts pass, which the send wakes.
    func fetchSocialAvatar(network: String, contact: ContactRecord, in book: AddressBookRecord) async throws {
        guard let queue else { throw Failure.noQueue }
        guard !book.isReadOnly else { throw Failure.readOnly }
        guard
            let payload = ContactWriteHandler.socialAvatarPayload(
                loginId: loginId, contact: contact, bookURL: book.url, network: network)
        else { throw Failure.noUID }
        try await queue.perform(.contactSocialAvatar(payload), loginId: loginId)
    }

    /// The book a new contact goes into: the one being shown when it is writable, else the
    /// login's own "Contacts", else any writable book. Never Recently contacted.
    static func defaultBook(for scope: ContactsScope, books: [AddressBookRecord]) -> AddressBookRecord? {
        let writable = books.filter { $0.isEnabled && !$0.isReadOnly && !ContactsListing.isRecentlyContacted($0) }
        if case .addressBook(let id) = scope, let shown = writable.first(where: { $0.id == id }) { return shown }
        return writable.first { $0.sharedBy == nil && $0.url.hasSuffix("/contacts/") }
            ?? writable.first { $0.sharedBy == nil } ?? writable.first
    }

    /// Why a book cannot be edited, or nil when it can.
    static func readOnlyReason(_ book: AddressBookRecord?) -> String? {
        guard let book else { return String(localized: "This contact's address book is not on this Mac.") }
        guard book.isReadOnly else { return nil }
        let name = book.displayName ?? String(localized: "This address book")
        if let owner = book.sharedBy, !owner.isEmpty {
            return String(localized: "\(name) is shared read-only by \(owner), so its contacts cannot be edited.")
        }
        return String(localized: "\(name) is read-only, so its contacts cannot be edited.")
    }
}
