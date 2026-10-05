// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// The address-book, import and merge writes, as queued operations like every other contact
/// write (ADR-0069, ADR-0096): each lands in the mirror at once and reaches the server when
/// the drainer runs, so all of them work offline.
@MainActor
struct AddressBookActions {
    enum Failure: Error, Equatable {
        case noQueue
        case readOnly
        /// The book is another user's share: only its owner can rename, share or delete it.
        case notOwner
        case noHome
        case emptyName
    }

    let loginId: Int64
    let store: MailStore
    let queue: MutationQueue?

    init(_ actions: ContactsActions) {
        loginId = actions.loginId
        store = actions.store
        queue = actions.queue
    }

    init(loginId: Int64, store: MailStore, queue: MutationQueue?) {
        self.loginId = loginId
        self.store = store
        self.queue = queue
    }

    // MARK: - Address books

    /// MKCOL (extended) of a new book under the login's address-book home. Answers its href.
    @discardableResult
    func create(name: String, books: [AddressBookRecord], fallbackHome: String?) async throws -> String {
        guard let queue else { throw Failure.noQueue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        guard let href = Self.newCollectionHref(name: trimmed, books: books, fallbackHome: fallbackHome) else {
            throw Failure.noHome
        }
        let payload = DAVWritePayload(
            loginId: loginId, href: href, displayName: trimmed, before: DAVWriteSnapshot(existed: false))
        try await queue.perform(.addressBookCreate(payload), loginId: loginId)
        return href
    }

    func rename(_ book: AddressBookRecord, to name: String) async throws {
        guard let queue else { throw Failure.noQueue }
        guard book.sharedBy == nil else { throw Failure.notOwner }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        guard trimmed != book.displayName else { return }
        let payload = DAVWritePayload(
            loginId: loginId, addressBookId: book.id, href: Self.href(book), displayName: trimmed,
            before: DAVWriteSnapshot(displayName: book.displayName))
        try await queue.perform(.addressBookUpdate(payload), loginId: loginId)
    }

    /// Web Contacts' per-book toggle: `oc:enabled` on the collection, so it follows the user
    /// to the browser and every other client.
    func setEnabled(_ enabled: Bool, book: AddressBookRecord) async throws {
        guard let queue else { throw Failure.noQueue }
        guard enabled != book.isEnabled else { return }
        let payload = DAVWritePayload(
            loginId: loginId, addressBookId: book.id, href: Self.href(book), enabled: enabled,
            before: DAVWriteSnapshot(displayName: book.displayName))
        try await queue.perform(.addressBookUpdate(payload), loginId: loginId)
    }

    /// Shares the book with a user or group; sharing again with the same sharee changes the
    /// read-only flag, as the server's share POST replaces the previous access.
    func share(_ book: AddressBookRecord, with sharee: ShareeSuggestion, readOnly: Bool) async throws {
        guard let queue else { throw Failure.noQueue }
        guard book.sharedBy == nil else { throw Failure.notOwner }
        let payload = DAVWritePayload(
            loginId: loginId, addressBookId: book.id, href: Self.href(book), sharee: Self.principal(for: sharee),
            shareReadOnly: readOnly)
        try await queue.perform(.addressBookShare(payload), loginId: loginId)
    }

    func delete(_ book: AddressBookRecord) async throws {
        guard let queue else { throw Failure.noQueue }
        guard book.sharedBy == nil else { throw Failure.notOwner }
        let payload = DAVWritePayload(
            loginId: loginId, addressBookId: book.id, href: Self.href(book),
            before: DAVWriteSnapshot(displayName: book.displayName))
        try await queue.perform(.addressBookDelete(payload), loginId: loginId)
    }

    // MARK: - Cards

    /// Queues one `contactPut` per card, reporting progress after each. The queue has no batch
    /// verb and does not need one: each card is its own request on the wire anyway, and a
    /// row per card is what lets Discard and conflicts work per contact.
    func importCards(
        _ plan: VCardImportPlan, into book: AddressBookRecord, progress: (Int) -> Void
    ) async throws {
        guard let queue else { throw Failure.noQueue }
        guard !book.isReadOnly else { throw Failure.readOnly }
        guard let bookId = book.id else { throw Failure.noHome }
        for (index, item) in plan.items.enumerated() {
            try Task.checkCancellation()
            let payload = VCardImportPlan.payload(item, loginId: loginId, addressBookId: bookId)
            try await queue.perform(.contactPut(payload), loginId: loginId)
            progress(index + 1)
        }
    }

    /// Writes the merged card over `kept` and deletes `other`: one `contactPut` and one
    /// `contactDelete`, in that order, so a failure in between loses nothing.
    func merge(
        _ plan: ContactMergePlan, kept: ContactRecord, other: ContactRecord, books: [AddressBookRecord],
        now: Date = Date()
    ) async throws {
        guard let queue else { throw Failure.noQueue }
        guard let keptBook = books.first(where: { $0.id == kept.addressBookId }), !keptBook.isReadOnly,
            let otherBook = books.first(where: { $0.id == other.addressBookId }), !otherBook.isReadOnly
        else { throw Failure.readOnly }
        let put = ContactWriteHandler.putPayload(
            loginId: loginId, addressBookId: kept.addressBookId, existing: kept, card: plan.merged(now: now))
        try await queue.perform(.contactPut(put), loginId: loginId)
        try await ContactsActions(loginId: loginId, store: store, queue: queue).delete([other], books: books)
    }

    // MARK: - Pure helpers

    /// The collection's host-relative path, as a multistatus spells it.
    nonisolated static func href(_ book: AddressBookRecord) -> String {
        guard let url = URL(string: book.url) else { return book.url }
        var path = url.path(percentEncoded: true)
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    /// `<home>/<slug>/` for a new book. The home is the parent of any listed book (they all
    /// live in the login's `addressbooks/users/<id>/`, shares included); with none listed,
    /// `fallbackHome`. The slug is the name lowercased with anything but letters, digits, `-`
    /// and `_` turned into `-`, numbered when taken.
    nonisolated static func newCollectionHref(
        name: String, books: [AddressBookRecord], fallbackHome: String?
    ) -> String? {
        let paths = books.map(href)
        let home: String
        if let first = paths.first {
            var parts = first.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { return nil }
            parts.removeLast()
            home = "/" + parts.joined(separator: "/") + "/"
        } else if let fallbackHome {
            home = fallbackHome.hasSuffix("/") ? fallbackHome : fallbackHome + "/"
        } else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        var slug = String(
            String.UnicodeScalarView(
                name.lowercased().unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "addressbook" }
        let taken = Set(paths.map { $0.lowercased() })
        var candidate = home + slug + "/"
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = home + slug + "-\(number)/"
            number += 1
        }
        return candidate
    }

    /// `principals/users/<id>` or `principals/groups/<id>`, with the `principal:` scheme the
    /// share POST's `href` takes.
    static func principal(for sharee: ShareeSuggestion) -> String {
        let kind = sharee.type == "group" ? "groups" : "users"
        let id = sharee.shareWith.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sharee.shareWith
        return "principal:principals/\(kind)/\(id)"
    }

    /// The login's address-book home when it has no book to derive it from:
    /// `<server path>/remote.php/dav/addressbooks/users/<login>/`.
    nonisolated static func fallbackHome(serverURL: URL, userId: String) -> String {
        var base = serverURL.path(percentEncoded: true)
        if base.hasSuffix("/") { base.removeLast() }
        let user = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        return base + "/remote.php/dav/addressbooks/users/\(user)/"
    }
}
