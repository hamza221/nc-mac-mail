// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet
public import NCMailStore

/// Fills the `avatar` table for one account's correspondents.
///
/// The network writes the database and views read it: `NCAvatar`'s loader waits on the
/// `avatar` row and never asks the server itself, so this actor is the only thing that does.
/// It walks the account's senders newest-correspondent first, so the people at the top of
/// the inbox get their pictures before anyone else.
///
/// It only uses `GET /api/avatars/image/{email}`. The server fetches Gravatar and favicon
/// images itself, so a sender never sees the reader's address, and it answers 404 for
/// everything else. That includes contacts whose vCard photo is a URI: the server reports
/// those as internal and won't serve them through this route. Fetching those would mean
/// requesting an arbitrary URL from the address book directly, which this client doesn't do
/// (ADR-0061).
public actor AvatarFetcher {
    /// Addresses per database round trip.
    public static let batchSize = 25
    /// Requests in flight at once. The route is cheap for the server when it has the image
    /// cached and expensive when it has to go to Gravatar, so this stays small.
    public static let concurrency = 4
    /// How long between passes once there is nothing left to ask about.
    public static let idleInterval: Duration = .seconds(600)
    /// A photo older than this is asked for again.
    public static let photoLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// A 404 older than this is asked about again, so a new Gravatar shows within the week.
    public static let missingLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let store: MailStore
    private let client: MailClient
    private let accountId: Int64
    private let now: @Sendable () -> Date

    private var conditions = MirrorConditions()
    private var loop: Task<Void, Never>?

    public init(
        store: MailStore,
        client: MailClient,
        accountId: Int64,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.client = client
        self.accountId = accountId
        self.now = now
    }

    /// Starts the loop: a pass, then idle, forever, until ``stop()``.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.mayRun { _ = await self.runPass() }
                try? await Task.sleep(for: Self.idleInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Offline, nothing can be asked. In Low Data Mode, pictures are exactly the kind of
    /// bytes the user asked apps to hold back. Coming back online starts a pass immediately.
    public func apply(conditions newConditions: MirrorConditions) {
        let wasPaused = !mayRun
        conditions = newConditions
        if wasPaused, mayRun, loop != nil {
            stop()
            start()
        }
    }

    private var mayRun: Bool { !conditions.isOffline && !conditions.isConstrained }

    /// Asks about every address that needs it, batch by batch, and returns how many rows it
    /// wrote. Ends at the first failure that is not a 404, so an outage costs one batch
    /// rather than one request per correspondent.
    @discardableResult
    public func runPass() async -> Int {
        var written = 0
        while mayRun, !Task.isCancelled {
            let current = now().timeIntervalSince1970
            let batch: [String]
            do {
                batch = try await store.sendersNeedingAvatars(
                    accountId: accountId,
                    staleBefore: Int64(current - Self.photoLifetime),
                    retryMissingBefore: Int64(current - Self.missingLifetime),
                    limit: Self.batchSize
                )
            } catch {
                MirrorLog.mirror.error(
                    "avatar work list failed for account \(self.accountId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return written
            }
            guard !batch.isEmpty else { return written }

            do {
                written += try await fetch(batch, fetchedAt: Int64(current))
            } catch {
                // `MailError`'s description carries a status and a kind, never the URL, so
                // the address the request named does not reach the log.
                MirrorLog.mirror.info(
                    "avatar pass for account \(self.accountId, privacy: .public) stopped: \(String(describing: error), privacy: .public)"
                )
                return written
            }
        }
        return written
    }

    /// One batch, `concurrency` at a time. Every address answered gets a row, either the
    /// bytes or `missing`, which is what guarantees the next batch is a different one.
    private func fetch(_ emails: [String], fetchedAt: Int64) async throws -> Int {
        let store = store
        let client = client
        return try await withThrowingTaskGroup(of: Void.self) { group in
            var written = 0
            var pending = emails[...]
            func enqueue() {
                guard let email = pending.popFirst() else { return }
                group.addTask {
                    try await Self.fetchOne(email, store: store, client: client, fetchedAt: fetchedAt)
                }
            }
            for _ in 0..<Self.concurrency { enqueue() }
            while try await group.next() != nil {
                written += 1
                enqueue()
            }
            return written
        }
    }

    private static func fetchOne(_ email: String, store: MailStore, client: MailClient, fetchedAt: Int64) async throws {
        let record: AvatarRecord
        do {
            let (data, response) = try await client.bytes(.avatar(email: email))
            record =
                data.isEmpty
                ? AvatarRecord(email: email, missing: true, fetchedAt: fetchedAt)
                : AvatarRecord(
                    email: email,
                    data: data,
                    mime: response.mimeType,
                    isExternal: true,
                    fetchedAt: fetchedAt
                )
        } catch MailError.notFound {
            record = AvatarRecord(email: email, missing: true, fetchedAt: fetchedAt)
        }
        try await store.upsert(avatar: record)
    }
}
