// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// The two writes the contact card makes — "Add to contact" and "New contact" — as queued
/// `contactPut`s (ADR-0069, ADR-0081). No HTTP here: the queue applies the card locally in
/// the same transaction and the drainer sends it when there is a network.
nonisolated enum ContactCardActions {
    enum Failure: Error, Equatable {
        /// The login has no running engine (signed out), so there is no queue to write to.
        case noQueue
        /// The stored card does not parse, and rewriting it would lose what it holds.
        case unreadableCard
        case noSuchContact
    }

    /// The card with `email` appended as one more `EMAIL`, or nil when it already carries
    /// the address (case-insensitively) and there is nothing to write.
    static func card(adding email: String, to vcard: String) throws -> VCard? {
        guard var card = try? VCardParser.parse(vcard).first else { throw Failure.unreadableCard }
        let wanted = email.lowercased()
        guard !card.emails.contains(where: { $0.value.lowercased() == wanted }) else { return nil }
        card.addProperty(DirectoryProperty(name: "EMAIL", value: escape(email)))
        return card
    }

    /// A new vCard 3.0 for one person, in the shape web Contacts writes: `UID`, `FN`, `N`
    /// split at the last space, and the address.
    static func newCard(name: String, email: String, uid: String) -> VCard {
        var card = VCard(version: "3.0")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? email : trimmed
        card.setProperty("UID", to: escape(uid))
        card.setProperty("FN", to: escape(displayName))
        var words = trimmed.split(separator: " ").map(String.init)
        let family = words.count > 1 ? words.removeLast() : ""
        let given = words.joined(separator: " ")
        card.setProperty("N", to: [family, given, "", "", ""].map(escape).joined(separator: ";"))
        card.addProperty(DirectoryProperty(name: "EMAIL", value: escape(email)))
        return card
    }

    /// Where a new card goes: `<book path><UID>.vcf`, host-relative as a multistatus spells
    /// hrefs, so the next `sync-collection` recognises the row the queue already wrote.
    static func newHref(bookURL: String, uid: String) -> String? {
        guard let url = URL(string: bookURL) else { return nil }
        var path = url.path(percentEncoded: true)
        if !path.hasSuffix("/") { path += "/" }
        return path + uid + ".vcf"
    }

    /// Queues the address onto an existing contact. Returns false when the card already had it.
    @MainActor
    static func add(
        email: String, toContact contactId: Int64, loginId: Int64, store: MailStore, queue: MutationQueue?
    )
        async throws -> Bool
    {
        guard let queue else { throw Failure.noQueue }
        guard let existing = try await store.contact(id: contactId) else { throw Failure.noSuchContact }
        guard let card = try card(adding: email, to: existing.vcard) else { return false }
        let payload = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: existing.addressBookId, existing: existing, card: card)
        try await queue.perform(.contactPut(payload), loginId: loginId)
        return true
    }

    /// Queues a new contact into `book`.
    @MainActor
    static func create(
        name: String, email: String, in book: AddressBookRecord, loginId: Int64, queue: MutationQueue?,
        uid: String = UUID().uuidString
    ) async throws {
        guard let queue else { throw Failure.noQueue }
        guard let bookId = book.id, let href = newHref(bookURL: book.url, uid: uid) else { throw Failure.noSuchContact }
        let payload = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: bookId, existing: nil, card: newCard(name: name, email: email, uid: uid),
            newHref: href)
        try await queue.perform(.contactPut(payload), loginId: loginId)
    }

    /// RFC 6350 §3.4 text escaping for a value written by hand.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case ",": result += "\\,"
            case ";": result += "\\;"
            case "\n": result += "\\n"
            case "\r": continue
            default: result.append(character)
            }
        }
        return result
    }
}
