// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// The wiring every sync test repeats, and the one thing that needs explaining: where the
/// JSON comes from.
///
/// **Nothing here writes a payload by hand.** The house rule is that a fixture someone typed
/// tests that the decoder matches that person's idea of the shape, which is the thing most
/// likely to be wrong. But a sync test needs situations the recorder cannot capture on
/// demand — a message vanishing, a reply landing in an existing thread, a page boundary
/// falling between two messages that share a `dateInt`. So ``Recorded`` **re-cuts** the
/// recorded bytes: it slices, reorders and moves ids between the lists of a real response,
/// and every envelope object inside is byte-for-byte what the live server sent. A field is
/// only ever changed where the test is about that field, and each of those says so.
enum SyncTest {
    static func configuration(
        clock: TestClock,
        windowSize: Int = SyncWindow.size,
        pageSize: Int = SyncWindow.pageSize,
        mailboxConcurrency: Int = 3,
        tailScanPageLimit: Int = 20
    ) -> SyncConfiguration {
        SyncConfiguration(
            windowSize: windowSize,
            pageSize: pageSize,
            mailboxConcurrency: mailboxConcurrency,
            syncInProgressBackoff: [.zero],
            failureBackoffSeconds: [30],
            tailScanPageLimit: tailScanPageLimit,
            now: { clock.now },
            sleep: { _ in }
        )
    }

    /// A store holding one account, every recorded mailbox, and `messages` of the recorded
    /// inbox page written into the inbox — through the real write path, so the addresses
    /// table and the search index are populated exactly as a live sync leaves them.
    struct Seeded {
        var store: MailStore
        var accountId: Int64
        var inboxId: Int64
        /// The server's id for the inbox, which is what every route is keyed by. Read from
        /// the recording, because the recorder tracks whatever the dev server holds.
        var inboxRemoteId: Int
        /// The mirror's ids of the seeded messages, keyed by the server's.
        var localByRemote: [Int64: Int64]
    }

    static func seed(messages: [[String: Any]]) async throws -> Seeded {
        let store = try MailStore.inMemory()
        let accountId = try await MirrorTest.mirroredAccount(store)
        let list = try JSONDecoder().decode(MailboxList.self, from: try FixtureBytes.data("mailboxes-account.json"))
        let mailboxes = try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: accountId) },
            accountId: accountId
        )
        let inbox = try #require(mailboxes.first { $0.specialRole == "inbox" })

        var localByRemote: [Int64: Int64] = [:]
        if !messages.isEmpty {
            let envelopes = try JSONDecoder().decode(
                [RawBacked<Envelope>].self,
                from: try Recorded.data(messages)
            )
            let writes = try envelopes.map {
                try MirrorMapping.envelopeWrite($0, accountId: accountId, mailboxId: inbox.id, syncedAt: 1)
            }
            let ids = try await store.upsert(envelopes: writes)
            localByRemote = Dictionary(
                zip(writes.map(\.remoteId), ids),
                uniquingKeysWith: { first, _ in first }
            )
        }
        return Seeded(
            store: store,
            accountId: accountId,
            inboxId: inbox.id,
            inboxRemoteId: Int(inbox.remoteId),
            localByRemote: localByRemote
        )
    }

    /// A scheduler over `seeded`, with every route the first pass touches already answered:
    /// the sort-order preference, the accounts refresh and the folder list. A test then
    /// stubs only the route it is about.
    static func scheduler(
        _ seeded: Seeded,
        transport: FakeTransport,
        configuration: SyncConfiguration,
        drainer: (any OperationDraining)? = nil,
        sortOrder: String? = nil
    ) async throws -> SyncScheduler {
        try await stubBoilerplate(transport, sortOrder: sortOrder)
        return SyncScheduler(
            store: seeded.store,
            client: try MirrorTest.client(transport),
            accountId: seeded.accountId,
            drainer: drainer,
            mirror: nil,
            configuration: configuration
        )
    }

    /// - Parameter sortOrder: `oldest`, for the tests about an account that set it. The
    ///   recorded fixture is the unset case, which is the server default and therefore
    ///   `newest`; there is no recording of the other value because setting a preference on
    ///   the shared test server to record one would change it for everybody. The shape is
    ///   the fixture's, one string apart.
    static func stubBoilerplate(_ transport: FakeTransport, sortOrder: String? = nil) async throws {
        if let sortOrder {
            await transport.stub(sortOrderRoute, with: .json(#"{"value":"\#(sortOrder)"}"#))
        } else {
            await transport.stub(sortOrderRoute, with: try .fixture("preference-sort-order.json"))
        }
        await transport.stub(MirrorTest.accountsRoute, with: try .fixture("accounts.json"))
        await transport.stub(MirrorTest.mailboxesRoute, with: try .fixture("mailboxes-account.json"))
    }

    static let sortOrderRoute = RequestMatcher.pathSuffix("/preferences/sort-order")

    /// Requests the boilerplate accounts for, so a test asserting on a cycle's request count
    /// can subtract what it did not ask about.
    static let boilerplateRequests = 3

    /// Every mirrored, selectable mailbox that is *not* the inbox. Answered with recordings
    /// that carry nothing, so a test can say what the inbox does without describing the
    /// rest of the account.
    static func stubQuietMailboxes(_ transport: FakeTransport) async throws {
        for other in try MirrorTest.recordedMailboxes().others {
            await transport.stub(MirrorTest.syncRoute(mailboxId: other), with: try .fixture("sync-incremental.json"))
            await transport.stub(
                MirrorTest.messagesRoute(mailboxId: other),
                with: try .fixture("messages-inbox-page2.json")
            )
        }
    }
}

/// The recorded inbox page, sliced and re-assembled.
///
/// `[String: Any]` rather than a model, deliberately: the point is that every envelope
/// object goes back out exactly as it came in, including the fields no Swift type names.
/// Nothing here crosses an `await`.
enum Recorded {
    /// The recorded envelopes, newest first — the order the server returns them in under the
    /// default `newest` sort.
    static func inbox() throws -> [[String: Any]] {
        let raw = try JSONSerialization.jsonObject(with: try FixtureBytes.data("messages-inbox-page1.json"))
        let rows = try #require(raw as? [[String: Any]])
        return rows.sorted { dateInt($0) > dateInt($1) }
    }

    static func dateInt(_ row: [String: Any]) -> Int64 {
        (row["dateInt"] as? NSNumber)?.int64Value ?? 0
    }

    static func id(_ row: [String: Any]) -> Int64 {
        (row["databaseId"] as? NSNumber)?.int64Value ?? 0
    }

    static func ids(_ rows: [[String: Any]]) -> [Int64] {
        rows.map(id)
    }

    /// The first two recorded envelopes that share a `dateInt`, newest-first order kept.
    ///
    /// The premise of every cursor test: a page boundary between these two is the one the
    /// strict `<` makes unreachable. The live account is seeded with such a pair (two
    /// self-sends in the same second) so the recording carries it; a recording without one
    /// fails here, loudly, rather than letting those tests pass about nothing.
    static func sharedDateIntPair(_ rows: [[String: Any]]) throws -> (first: [String: Any], second: [String: Any]) {
        let index = try #require(
            rows.indices.dropLast().first { dateInt(rows[$0]) == dateInt(rows[$0 + 1]) },
            "the recorded inbox holds no two messages sharing a dateInt; re-seed the live account"
        )
        return (rows[index], rows[index + 1])
    }

    /// The page a server with this sort order would answer for `cursor`: strictly older than
    /// it, newest first, at most `limit`.
    ///
    /// A model of `MessagesController::index`, written so a test can prove the *client's*
    /// cursor arithmetic against the *server's* comparison rather than against another copy
    /// of the client's. The `<` is the measured behaviour, not an assumption.
    static func page(_ rows: [[String: Any]], cursor: Int64?, limit: Int) -> [[String: Any]] {
        let eligible = cursor.map { bound in rows.filter { dateInt($0) < bound } } ?? rows
        return Array(eligible.prefix(limit))
    }

    static func data(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    static func page(_ rows: [[String: Any]]) throws -> StubResponse {
        StubResponse(status: 200, body: try data(rows))
    }

    /// A `POST /sync` response built from recorded envelopes.
    static func syncResponse(
        new: [[String: Any]] = [],
        changed: [[String: Any]] = [],
        vanished: [Int64] = [],
        total: Int,
        unread: Int
    ) throws -> StubResponse {
        let object: [String: Any] = [
            "newMessages": new,
            "changedMessages": changed,
            "vanishedMessages": vanished.map(NSNumber.init(value:)),
            "stats": ["total": total, "unread": unread],
        ]
        return StubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }

    /// One recorded envelope with one flag flipped.
    ///
    /// The only field any test here rewrites, and only in the conflict tests, whose whole
    /// subject is "the server says X and the queue says not-X".
    static func settingFlag(_ name: String, to value: Bool, on row: [[String: Any]]) -> [[String: Any]] {
        row.map { entry in
            var copy = entry
            var flags = copy["flags"] as? [String: Any] ?? [:]
            flags[name] = value
            copy["flags"] = flags
            return copy
        }
    }
}

/// A drainer that records that it was asked, and answers with whatever the test is holding.
///
/// `Mutex` rather than an actor because ``order`` has to be readable from a synchronous
/// assertion, and rather than an unchecked conformance because the house rules ban those.
final class FakeDrainer: OperationDraining {
    private let intents: Mutex<[PendingIntent]>
    private let drains: Mutex<Int>
    /// Set by the test's transport stub, so "the drain ran before the first request" is an
    /// assertion rather than a hope.
    let sawRequestBeforeDrain = Mutex(false)

    init(intents: [PendingIntent] = []) {
        self.intents = Mutex(intents)
        drains = Mutex(0)
    }

    var drainCount: Int { drains.withLock { $0 } }

    func setIntents(_ newIntents: [PendingIntent]) {
        intents.withLock { $0 = newIntents }
    }

    func drain() async {
        drains.withLock { $0 += 1 }
    }

    func pendingIntents() async -> [PendingIntent] {
        intents.withLock { $0 }
    }
}
