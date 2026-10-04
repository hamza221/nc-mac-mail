// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet
public import NCMailStore
internal import OSLog

/// What one pass did, for tests, the live measurement and the log.
public struct ContactsSyncReport: Sendable, Equatable {
    public var booksListed = 0
    /// Books whose token moved and that got a `sync-collection` round.
    public var booksSynced = 0
    public var cardsWritten = 0
    public var cardsDeleted = 0
    /// Changed hrefs left alone because a queued write owns them.
    public var cardsHeldForPendingWrites = 0
    public var multigetRequests = 0

    public init() {}
}

/// The CardDAV mirror of one Nextcloud login (ADR-0069): every address book and every card,
/// offline-readable, kept current with RFC 6578 `sync-collection`.
///
/// One actor per login, not per mail account — a login has one set of address books however
/// many mail accounts it carries. It only writes the store; views observe it. Writes the
/// user makes go through the queue and ``ContactWriteHandler``, never through here.
///
/// The spec is `docs/architecture/sync-engine.md`, "contacts and the calendar list".
public actor ContactsSync {
    /// Between passes when nothing wakes it.
    public static let interval: Duration = .seconds(600)
    /// hrefs per `addressbook-multiget`.
    public static let multigetBatchSize = 100
    /// How often every contact photo is written into `avatar` again, so `AvatarFetcher`'s
    /// 30-day staleness can never reach one and replace it with a server guess (ADR-0061).
    public static let photoReassertInterval: TimeInterval = 24 * 60 * 60

    private let store: MailStore
    private let client: DAVClient
    private let loginId: Int64
    private let pendingWrites: @Sendable () async throws -> [DAVWrite]
    private let now: @Sendable () -> Date

    private var conditions = MirrorConditions()
    private var homes: (principal: URL, addressbookHome: URL?)?
    private var loop: Task<Void, Never>?
    private var current: Task<ContactsSyncReport?, Never>?
    private var lastPhotoReassert: Date?

    /// - Parameter pendingWrites: the login's queued DAV writes —
    ///   `{ try await queue.pendingDAVWrites(loginId:) }` in the app. A card one of them
    ///   touches is never overwritten by a sync.
    public init(
        store: MailStore,
        client: DAVClient,
        loginId: Int64,
        pendingWrites: @escaping @Sendable () async throws -> [DAVWrite],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        self.loginId = loginId
        self.pendingWrites = pendingWrites
        self.now = now
    }

    // MARK: - Scheduling

    /// A pass now, then one every ``interval``, until ``stop()``.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.syncNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The Mac woke, or the network came back: a pass now, without waiting for the timer.
    public func wake() {
        Task { _ = await self.syncNow() }
    }

    /// Offline, every pass is a no-op and nothing is touched. Coming back online wakes.
    public func apply(conditions newConditions: MirrorConditions) {
        let wasOffline = conditions.isOffline
        conditions = newConditions
        if wasOffline, !newConditions.isOffline { wake() }
    }

    /// Runs a pass, or joins the one in flight. Nil when offline or when the pass failed
    /// (the failure is logged; the mirror is left as it was).
    @discardableResult
    public func syncNow() async -> ContactsSyncReport? {
        if let current { return await current.value }
        let task = Task { () -> ContactsSyncReport? in
            do {
                return try await self.runPass()
            } catch {
                ContactsLog.contacts.error(
                    "login \(self.loginId, privacy: .public) contacts pass failed: \(describeDAV(error), privacy: .public)"
                )
                return nil
            }
        }
        current = task
        let report = await task.value
        current = nil
        return report
    }

    // MARK: - The pass

    /// Discovery → listing → one `sync-collection` round per changed book.
    public func runPass() async throws -> ContactsSyncReport {
        var report = ContactsSyncReport()
        guard !conditions.isOffline else { return report }

        let homes = try await discoveredHomes()
        guard let home = homes.addressbookHome else { return report }

        let resources: [DAVResource]
        do {
            resources = try await client.propfind(home, depth: .one, properties: AddressBookListing.properties)
        } catch DAVError.notFound {
            // The home moved (an instance migration); rediscover next pass.
            self.homes = nil
            throw DAVError.notFound
        }
        let listing = AddressBookListing.parse(
            resources, client: client, ownPrincipalPath: homes.principal.path(percentEncoded: false))
        report.booksListed = listing.count

        let pending = try await pendingWrites()
        let heldHrefs = Set(
            pending.filter { $0.kind == .contactPut || $0.kind == .contactDelete }.compactMap(\.payload.href))
        let pendingBookUpdates = Set(
            pending.filter { $0.kind == .addressBookUpdate }.compactMap(\.payload.addressBookId))

        let rows = try await store.syncAddressBooks(
            listing.enumerated().map { $1.record(loginId: loginId, position: $0) },
            loginId: loginId
        )
        let byURL = Dictionary(listing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        for var row in rows {
            guard let id = row.id, let listed = byURL[row.url] else { continue }
            // The toggle lives on the server (`oc:enabled`); the store keeps the local value
            // on update, so the listing is applied here — unless a queued update owns it.
            if listed.isEnabled != row.isEnabled, !pendingBookUpdates.contains(id) {
                try await store.setAddressBookEnabled(listed.isEnabled, addressBookId: id)
                row.isEnabled = listed.isEnabled
            }
            try Task.checkCancellation()
            do {
                if listed.syncToken == nil {
                    // No token means no sync-collection on this book (measured: "Recently
                    // contacted" answers 415 ReportNotSupported). An ETag listing does instead.
                    try await syncBookByListing(row, heldHrefs: heldHrefs, report: &report)
                } else {
                    if let token = row.syncToken, token == listed.syncToken { continue }
                    try await syncBook(row, heldHrefs: heldHrefs, report: &report)
                }
                report.booksSynced += 1
            } catch let error as DAVError {
                if case .transport = error { throw error }
                if case .unauthorized = error { throw error }
                // One book's server error does not cost the others their round.
                ContactsLog.contacts.error(
                    "address book \(id, privacy: .public) round failed: \(describeDAV(error), privacy: .public)")
            }
        }

        if lastPhotoReassert.map({ now().timeIntervalSince($0) >= Self.photoReassertInterval }) ?? true {
            try await reassertPhotos(rows.filter(\.isEnabled))
            lastPhotoReassert = now()
        }

        ContactsLog.contacts.info(
            """
            login \(self.loginId, privacy: .public) contacts pass: \(report.booksListed, privacy: .public) books, \
            \(report.booksSynced, privacy: .public) synced, \(report.cardsWritten, privacy: .public) written, \
            \(report.cardsDeleted, privacy: .public) deleted, \(report.cardsHeldForPendingWrites, privacy: .public) held
            """
        )
        return report
    }

    private func discoveredHomes() async throws -> (principal: URL, addressbookHome: URL?) {
        if let homes { return homes }
        let principal = try await client.currentUserPrincipal()
        let sets = try await client.homeSets(of: principal)
        let found = (principal: principal, addressbookHome: sets.addressbookHome)
        homes = found
        return found
    }

    /// One book's `sync-collection` round, to completion. The token is stamped last, so an
    /// interrupted round resumes from the previous one and loses nothing.
    private func syncBook(
        _ book: AddressBookRecord, heldHrefs: Set<String>, report: inout ContactsSyncReport
    ) async throws {
        guard let bookId = book.id, let url = URL(string: book.url) else { return }
        var local = Dictionary(
            try await store.contacts(addressBookId: bookId).map { ($0.href, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var token = book.syncToken
        var isInitial = token == nil
        var seen = Set<String>()

        while true {
            try Task.checkCancellation()
            let changes: DAVSyncChanges
            do {
                changes = try await client.syncCollection(url, token: token)
            } catch DAVError.forbidden(let exception, _)
                where token != nil && (exception?.contains("InvalidSyncToken") ?? false)
            {
                // Measured: 403 + Sabre\DAV\Exception\InvalidSyncToken. Start over.
                ContactsLog.contacts.notice("address book \(bookId, privacy: .public) token refused; full resync")
                token = nil
                isInitial = true
                seen = []
                continue
            }

            var toFetch: [String] = []
            for resource in changes.changed {
                seen.insert(resource.href)
                if heldHrefs.contains(resource.href) {
                    report.cardsHeldForPendingWrites += 1
                    continue
                }
                // Our own PUT echoed back, or an unchanged card listed on an initial sync.
                if let etag = resource.etag, local[resource.href]?.etag == etag { continue }
                toFetch.append(resource.href)
            }

            try await fetchAndWrite(toFetch, collection: url, book: book, local: &local, report: &report)

            for removedURL in changes.removed {
                let href = removedURL.path(percentEncoded: true)
                seen.insert(href)
                guard !heldHrefs.contains(href), let previous = local[href] else { continue }
                try await delete(previous, bookId: bookId, isEnabled: book.isEnabled)
                local[href] = nil
                report.cardsDeleted += 1
            }

            token = changes.newToken
            if !changes.truncated { break }
        }

        if isInitial {
            // A first round lists every member; anything else here is a leftover.
            for (href, previous) in local where !seen.contains(href) && !heldHrefs.contains(href) {
                try await delete(previous, bookId: bookId, isEnabled: book.isEnabled)
                report.cardsDeleted += 1
            }
        }
        try await store.setAddressBookSyncToken(
            token, lastSyncAt: Int64(now().timeIntervalSince1970), addressBookId: bookId)
    }

    /// A book without `sync-collection`: list every member's ETag, fetch what differs,
    /// delete what is gone. Runs every pass, since there is no token to compare; these books
    /// are small by nature (the server's own "Recently contacted").
    private func syncBookByListing(
        _ book: AddressBookRecord, heldHrefs: Set<String>, report: inout ContactsSyncReport
    ) async throws {
        guard let bookId = book.id, let url = URL(string: book.url) else { return }
        var local = Dictionary(
            try await store.contacts(addressBookId: bookId).map { ($0.href, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let collectionPath = url.path(percentEncoded: true)
        let members = try await client.propfind(url, depth: .one, properties: [.getetag])
            .filter { $0.etag != nil && $0.href != collectionPath && $0.href + "/" != collectionPath }
        let present = Set(members.map(\.href))
        var toFetch: [String] = []
        for member in members {
            if heldHrefs.contains(member.href) {
                report.cardsHeldForPendingWrites += 1
            } else if local[member.href]?.etag != member.etag {
                toFetch.append(member.href)
            }
        }
        try await fetchAndWrite(toFetch, collection: url, book: book, local: &local, report: &report)
        for (href, previous) in local where !present.contains(href) && !heldHrefs.contains(href) {
            try await delete(previous, bookId: bookId, isEnabled: book.isEnabled)
            report.cardsDeleted += 1
        }
        try await store.setAddressBookSyncToken(
            nil, lastSyncAt: Int64(now().timeIntervalSince1970), addressBookId: bookId)
    }

    /// `addressbook-multiget` in batches of ``multigetBatchSize``, one card per transaction.
    /// Only the hrefs asked for are written: a member the server answers about unasked is
    /// not this round's to decide (it may be held for a queued write).
    private func fetchAndWrite(
        _ hrefs: [String],
        collection url: URL,
        book: AddressBookRecord,
        local: inout [String: ContactRecord],
        report: inout ContactsSyncReport
    ) async throws {
        guard let bookId = book.id else { return }
        var start = 0
        while start < hrefs.count {
            try Task.checkCancellation()
            let batch = Array(hrefs[start..<min(start + Self.multigetBatchSize, hrefs.count)])
            start += Self.multigetBatchSize
            let requested = Set(batch)
            let fetched = try await client.addressbookMultiget(url, hrefs: batch)
            report.multigetRequests += 1
            for resource in fetched where requested.contains(resource.href) && (resource.status ?? 200) == 200 {
                guard let text = resource.addressData else { continue }
                let previous = local[resource.href]
                guard
                    let row = ContactMapping.row(
                        vcard: text,
                        href: resource.href,
                        etag: resource.etag,
                        addressBookId: bookId,
                        syncedAt: Int64(now().timeIntervalSince1970),
                        isFavorite: previous?.isFavorite ?? false
                    )
                else {
                    ContactsLog.contacts.error(
                        "address book \(bookId, privacy: .public): a card did not parse; skipped")
                    continue
                }
                let written = try await store.upsert(
                    contact: row.record, emails: row.emails, phones: row.phones, memberUids: row.memberUids)
                local[resource.href] = written
                report.cardsWritten += 1
                if book.isEnabled {
                    try await ContactAvatars.update(store: store, now: now(), new: row, previousVCard: previous?.vcard)
                }
            }
        }
    }

    private func delete(_ contact: ContactRecord, bookId: Int64, isEnabled: Bool) async throws {
        try await store.deleteContact(addressBookId: bookId, href: contact.href)
        if isEnabled {
            try await ContactAvatars.update(store: store, now: now(), new: nil, previousVCard: contact.vcard)
        }
    }

    /// Writes every enabled book's contact photos into `avatar` again (daily). See
    /// ``photoReassertInterval``.
    private func reassertPhotos(_ books: [AddressBookRecord]) async throws {
        for book in books {
            guard let id = book.id else { continue }
            for contact in try await store.contacts(addressBookId: id) {
                let (photo, emails) = ContactMapping.photoAndEmails(of: contact.vcard)
                guard let photo else { continue }
                try await ContactAvatars.write(photo, emails: emails, store: store, now: now())
            }
        }
    }
}
