// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore
public import NCMailNet
public import NCMailStore
internal import OSLog

/// The queue's `DAVWriteHandling` for one login: the local effect of each DAV kind, the
/// request, the 412 recovery, and Discard (ADR-0069, ADR-0082).
///
/// The queue owns order, persistence, backoff and the popover. This owns what a write means
/// to the mirror's rows and what to do when the server's copy moved on.
public struct ContactWriteHandler: DAVWriteHandling {
    private let store: MailStore
    private let client: DAVClient
    private let sender: DAVWriteSender
    private let conflicts: ContactConflictLog
    private let afterSend: @Sendable (DAVWrite) async -> Void
    private let now: @Sendable () -> Date

    /// - Parameter afterSend: called after a collection-level write reached the server
    ///   (create, rename, enable, delete, share, calendar object) — the app wakes
    ///   ``ContactsSync`` / ``CalendarListSync`` so the server's spelling of the result lands.
    public init(
        store: MailStore,
        client: DAVClient,
        conflicts: ContactConflictLog = ContactConflictLog(),
        afterSend: @escaping @Sendable (DAVWrite) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        sender = DAVWriteSender(client: client)
        self.conflicts = conflicts
        self.afterSend = afterSend
        self.now = now
    }

    // MARK: - Building a write

    /// The payload for saving `card` into a book: the full text, the base ETag, the
    /// edited property names and the `before` snapshot. `existing` nil creates a card at
    /// `newHref` (the caller picks the file name, `<UID>.vcf` like web Contacts).
    public static func putPayload(
        loginId: Int64,
        addressBookId: Int64,
        existing: ContactRecord?,
        card: VCard,
        newHref: String? = nil
    ) -> DAVWritePayload {
        let base = existing.flatMap { try? VCardParser.parse($0.vcard).first }
        return DAVWritePayload(
            loginId: loginId,
            addressBookId: addressBookId,
            contactId: existing?.id,
            href: existing?.href ?? newHref,
            body: String(decoding: VCardSerializer.serialize(card), as: UTF8.self),
            etag: existing?.etag,
            editedProperties: ContactMerge.editedProperties(from: base, to: card),
            before: DAVWriteSnapshot(existed: existing != nil, body: existing?.vcard, etag: existing?.etag)
        )
    }

    // MARK: - DAVWriteHandling

    public func apply(_ write: DAVWrite) async throws {
        let payload = write.payload
        switch write.kind {
        case .contactPut:
            guard let bookId = payload.addressBookId, let href = payload.href, let body = payload.body else { return }
            let existing = try await existingContact(payload)
            try await writeLocal(
                body: body, href: href, etag: existing?.etag ?? payload.etag, bookId: bookId, previous: existing)
        case .contactDelete:
            guard let bookId = payload.addressBookId, let href = payload.href else { return }
            try await store.deleteContact(addressBookId: bookId, href: href)
            try await ContactAvatars.update(store: store, now: now(), new: nil, previousVCard: payload.before.body)
        case .addressBookCreate:
            guard let href = payload.href else { return }
            var books = try await store.addressBooks(loginId: payload.loginId)
            let url = collectionURLString(client.resolve(href: href))
            guard !books.contains(where: { $0.url == url }) else { return }
            books.append(
                AddressBookRecord(
                    loginId: payload.loginId, url: url, displayName: payload.displayName,
                    isEnabled: payload.enabled ?? true, position: books.count))
            try await store.syncAddressBooks(books, loginId: payload.loginId)
        case .addressBookUpdate:
            try await updateBook(payload, displayName: payload.displayName, enabled: payload.enabled)
        case .addressBookDelete:
            guard let href = payload.href else { return }
            let url = collectionURLString(client.resolve(href: href))
            let books = try await store.addressBooks(loginId: payload.loginId)
            try await store.syncAddressBooks(books.filter { $0.url != url }, loginId: payload.loginId)
        default:
            // Shares and calendar objects have no mirrored rows; the next pass shows them.
            return
        }
    }

    public func send(_ write: DAVWrite) async throws {
        switch write.kind {
        case .contactPut:
            try await sendPut(write)
        case .contactDelete:
            try await sendDelete(write)
        default:
            try await sender.send(write)
            await afterSend(write)
        }
    }

    public func revert(_ write: DAVWrite) async {
        let payload = write.payload
        do {
            switch write.kind {
            case .contactPut:
                guard let bookId = payload.addressBookId, let href = payload.href else { return }
                let current = try await existingContact(payload)
                if payload.before.existed, let body = payload.before.body {
                    try await writeLocal(
                        body: body, href: href, etag: payload.before.etag, bookId: bookId, previous: current)
                } else {
                    try await store.deleteContact(addressBookId: bookId, href: href)
                    try await ContactAvatars.update(store: store, now: now(), new: nil, previousVCard: current?.vcard)
                }
            case .contactDelete:
                guard let bookId = payload.addressBookId, let href = payload.href, let body = payload.before.body else {
                    return
                }
                try await writeLocal(body: body, href: href, etag: payload.before.etag, bookId: bookId, previous: nil)
            case .addressBookCreate:
                guard let href = payload.href else { return }
                let url = collectionURLString(client.resolve(href: href))
                let books = try await store.addressBooks(loginId: payload.loginId)
                try await store.syncAddressBooks(books.filter { $0.url != url }, loginId: payload.loginId)
            case .addressBookUpdate:
                // `before` has no enabled field: the toggle is put back by inverting it.
                try await updateBook(
                    payload, displayName: payload.before.displayName, enabled: payload.enabled.map { !$0 })
            case .addressBookDelete:
                // The cards went with the row; a fresh row has no token, so the next pass
                // brings them all back.
                guard let href = payload.href else { return }
                var books = try await store.addressBooks(loginId: payload.loginId)
                books.append(
                    AddressBookRecord(
                        loginId: payload.loginId, url: collectionURLString(client.resolve(href: href)),
                        displayName: payload.before.displayName, position: books.count))
                try await store.syncAddressBooks(books, loginId: payload.loginId)
            default:
                return
            }
        } catch {
            ContactsLog.contacts.error(
                "revert of \(write.operationId, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    // MARK: - contactPut

    /// PUT with the base ETag; on 412 the per-property reapply onto the server's copy and
    /// one more PUT; a second 412 throws, and the queue parks the row as a conflict.
    private func sendPut(_ write: DAVWrite) async throws {
        let payload = write.payload
        guard let href = payload.href, let body = payload.body else { throw DAVError.notFound }
        let url = client.resolve(href: href)
        do {
            let etag = try await client.put(
                url, data: Data(body.utf8), contentType: Self.vcardType, ifMatch: payload.etag)
            try await recordSent(payload, sent: body, stored: body, etag: etag)
            return
        } catch DAVError.preconditionFailed {
            ContactsLog.contacts.info("contact write \(write.operationId, privacy: .public): 412, reapplying")
        }

        let server = try await fetchServerCopy(url)
        guard let local = try? VCardParser.parse(body).first else {
            throw DAVError.invalidResponse("queued vCard does not parse")
        }
        let merged: String
        let ifMatch: String?
        if let server, let serverCard = try? VCardParser.parse(server.text).first {
            let base = payload.before.body.flatMap { try? VCardParser.parse($0).first }
            let result = ContactMerge.reapply(
                local: local, onto: serverCard, base: base, editedProperties: payload.editedProperties)
            if !result.conflicts.isEmpty {
                await conflicts.record(
                    .init(
                        operationId: write.operationId, addressBookId: payload.addressBookId,
                        contactId: payload.contactId,
                        outcome: .localWon(properties: result.conflicts), at: now()))
            }
            merged = String(decoding: VCardSerializer.serialize(result.merged), as: UTF8.self)
            ifMatch = server.etag
        } else {
            // Deleted on the server while edited here: the edit is the user's latest word,
            // so the card is created again with what they saw.
            merged = body
            ifMatch = nil
        }

        do {
            let etag = try await client.put(url, data: Data(merged.utf8), contentType: Self.vcardType, ifMatch: ifMatch)
            try await recordSent(payload, sent: body, stored: merged, etag: etag)
        } catch DAVError.preconditionFailed {
            await conflicts.record(
                .init(
                    operationId: write.operationId, addressBookId: payload.addressBookId, contactId: payload.contactId,
                    outcome: .gaveUp, at: now()))
            throw DAVError.preconditionFailed
        }
    }

    /// After a successful PUT: the local row takes the stored text and the new ETag — but
    /// only if the user has not edited it again meanwhile, in which case that newer write
    /// is queued with the old ETag and will run its own reapply.
    private func recordSent(_ payload: DAVWritePayload, sent: String, stored: String, etag: String?) async throws {
        guard let bookId = payload.addressBookId, let href = payload.href else { return }
        let current = try await existingContact(payload)
        if let current, current.vcard != sent { return }
        // No ETag means the server may have rewritten the card (sabre does for 4.0); nil
        // makes the next sync refetch it.
        try await writeLocal(body: stored, href: href, etag: etag, bookId: bookId, previous: current)
    }

    // MARK: - contactDelete

    /// DELETE with the base ETag. A 412 means the server's copy is newer: the user's
    /// delete still wins, against the fresh ETag, and that is logged.
    private func sendDelete(_ write: DAVWrite) async throws {
        let payload = write.payload
        guard let href = payload.href else { throw DAVError.notFound }
        let url = client.resolve(href: href)
        do {
            try await client.delete(url, ifMatch: payload.etag)
        } catch DAVError.preconditionFailed {
            guard let server = try await fetchServerCopy(url) else { return }
            await conflicts.record(
                .init(
                    operationId: write.operationId, addressBookId: payload.addressBookId, contactId: payload.contactId,
                    outcome: .deletedNewer, at: now()))
            do {
                try await client.delete(url, ifMatch: server.etag)
            } catch DAVError.preconditionFailed {
                await conflicts.record(
                    .init(
                        operationId: write.operationId, addressBookId: payload.addressBookId,
                        contactId: payload.contactId,
                        outcome: .gaveUp, at: now()))
                throw DAVError.preconditionFailed
            }
        }
    }

    // MARK: - Helpers

    static let vcardType = "text/vcard; charset=utf-8"

    /// The server's current text and ETag for one card, by a one-href multiget on its
    /// collection; nil when it is gone.
    private func fetchServerCopy(_ url: URL) async throws -> (text: String, etag: String?)? {
        let collection = url.deletingLastPathComponent()
        let href = url.path(percentEncoded: true)
        let resources = try await client.addressbookMultiget(collection, hrefs: [href])
        guard let resource = resources.first(where: { $0.addressData != nil }), let text = resource.addressData else {
            return nil
        }
        return (text, resource.etag)
    }

    private func existingContact(_ payload: DAVWritePayload) async throws -> ContactRecord? {
        if let id = payload.contactId, let row = try await store.contact(id: id) { return row }
        guard let bookId = payload.addressBookId, let href = payload.href else { return nil }
        return try await store.contacts(addressBookId: bookId).first { $0.href == href }
    }

    private func writeLocal(
        body: String, href: String, etag: String?, bookId: Int64, previous: ContactRecord?
    ) async throws {
        guard
            let row = ContactMapping.row(
                vcard: body, href: href, etag: etag, addressBookId: bookId,
                syncedAt: Int64(now().timeIntervalSince1970), isFavorite: previous?.isFavorite ?? false)
        else { throw DAVError.invalidResponse("vCard does not parse") }
        try await store.upsert(contact: row.record, emails: row.emails, phones: row.phones, memberUids: row.memberUids)
        try await ContactAvatars.update(store: store, now: now(), new: row, previousVCard: previous?.vcard)
    }

    private func updateBook(_ payload: DAVWritePayload, displayName: String?, enabled: Bool?) async throws {
        var books = try await store.addressBooks(loginId: payload.loginId)
        let url = payload.href.map { collectionURLString(client.resolve(href: $0)) }
        guard let index = books.firstIndex(where: { $0.id == payload.addressBookId || $0.url == url }),
            let id = books[index].id
        else { return }
        if let displayName {
            books[index].displayName = displayName
            try await store.syncAddressBooks(books, loginId: payload.loginId)
        }
        if let enabled {
            try await store.setAddressBookEnabled(enabled, addressBookId: id)
        }
    }
}
