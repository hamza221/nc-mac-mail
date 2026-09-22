// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// One place for the wiring every mirror test repeats: a client pointed at a fake, a
/// configuration whose clock and sleeper the test owns, and matchers for the five routes
/// the backfill uses.
///
/// Nothing here sleeps, reads the wall clock or opens a socket, which is
/// `docs/delivery/definition-of-done.md`'s test rules in one paragraph.
enum MirrorTest {
    static let server = "https://cloud.example.invalid"
    static let apiRoot = "/index.php/apps/mail/api"

    /// The signed-in login every mirrored row here is filed under. A coordinator takes a
    /// local account id, and a local account id only exists once a row does (ADR-0033), so
    /// every test that runs one calls ``mirroredAccount(_:remoteId:)`` first.
    static let identity = ServerIdentity(serverURL: server + "/", loginName: "alice")

    /// The account row a coordinator is built for, and its local id.
    ///
    /// `remoteId` matches the first entry of `accounts.json`, so the refresh in `bootstrap`
    /// updates this row rather than adding another.
    static func mirroredAccount(_ store: MailStore, remoteId: Int64 = 1) async throws -> Int64 {
        let records = try await store.upsert(
            accounts: [
                AccountWrite(
                    identity: identity,
                    remoteId: remoteId,
                    name: "Test",
                    emailAddress: "alice@example.invalid"
                )
            ]
        )
        guard let account = records.first else { throw SetupError.accountNotWritten }
        return account.id
    }

    enum SetupError: Error { case badServerURL, accountNotWritten }

    static func client(_ transport: FakeTransport) throws -> MailClient {
        guard let url = URL(string: server) else { throw SetupError.badServerURL }
        return MailClient(
            server: url,
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport,
            // No retries inside the client. Every retry these tests assert on is the
            // mirror's own, and a client retry would double the counts and hide which layer
            // did the work.
            retryPolicy: .none,
            clientVersion: "test"
        )
    }

    /// - Parameter clock: shared with the test, so a cooldown can be aged without waiting.
    static func configuration(
        clock: TestClock = TestClock(),
        envelopePageSize: Int = 100,
        mailboxConcurrency: Int = 1,
        bodyConcurrency: Int = 2,
        bodyBatchSize: Int = 50,
        lowPowerMode: Bool = false
    ) -> MirrorConfiguration {
        MirrorConfiguration(
            envelopePageSize: envelopePageSize,
            mailboxConcurrency: mailboxConcurrency,
            bodyConcurrency: bodyConcurrency,
            bodyBatchSize: bodyBatchSize,
            primeBackoff: [.zero],
            now: { clock.now },
            sleep: { _ in },
            isLowPowerModeEnabled: { lowPowerMode }
        )
    }

    // MARK: - Matchers

    static let accountsRoute = RequestMatcher.path("\(apiRoot)/accounts")
    static let mailboxesRoute = RequestMatcher.path("\(apiRoot)/mailboxes")
    static let messagesRoute = RequestMatcher.path("\(apiRoot)/messages")
    static let bodyRoute = RequestMatcher.pathSuffix("/body")
    static let htmlRoute = RequestMatcher.pathSuffix("/html")
    static let anySyncRoute = RequestMatcher.pathSuffix("/sync")

    static func syncRoute(mailboxId: Int) -> RequestMatcher {
        .path("\(apiRoot)/mailboxes/\(mailboxId)/sync")
    }

    /// `GET /messages` for one mailbox. The id is in the query, not the path, so this is the
    /// one matcher `RequestMatcher`'s built-ins cannot express.
    static func messagesRoute(mailboxId: Int) -> RequestMatcher {
        messagesRoute
            && RequestMatcher("mailboxId=\(mailboxId)") { request in
                request.url?.query?.contains("mailboxId=\(mailboxId)") == true
            }
    }

    static func stubBootstrap(_ transport: FakeTransport) async throws {
        await transport.stub(accountsRoute, with: try .fixture("accounts.json"))
        await transport.stub(mailboxesRoute, with: try .fixture("mailboxes-account.json"))
    }

    /// Answers every mirrored mailbox except `except` from the two recordings that happen to
    /// carry nothing — a sync response with no new messages, and an empty message page — so
    /// a test can say what one mailbox does without stubbing the other four.
    static func stubQuietMailboxes(_ transport: FakeTransport, except mailboxId: Int) async throws {
        for other in [3, 4, 5, 6, 7] where other != mailboxId {
            await transport.stub(syncRoute(mailboxId: other), with: try .fixture("sync-incremental.json"))
            await transport.stub(messagesRoute(mailboxId: other), with: try .fixture("messages-inbox-page2.json"))
        }
    }

    /// Ids and `dateInt`s read out of the recorded inbox page, so an assertion is against
    /// what the server really sent rather than against a number typed into a test.
    struct RecordedInbox {
        let ids: [Int64]
        let oldestDateInt: Int64
        var count: Int { ids.count }
    }

    static func recordedInbox() throws -> RecordedInbox {
        struct Row: Decodable {
            let databaseId: Int64
            let dateInt: Int64
        }
        let rows = try JSONDecoder().decode([Row].self, from: try FixtureBytes.data("messages-inbox-page1.json"))
        return RecordedInbox(ids: rows.map(\.databaseId), oldestDateInt: rows.map(\.dateInt).min() ?? 0)
    }
}

/// A clock the test moves by hand. Unix seconds, matching `MirrorConfiguration.now`.
///
/// A `Mutex` rather than an actor because `MirrorConfiguration.now` is a synchronous
/// closure, and rather than an unchecked conformance because the house rules ban those
/// outright: a type that will not conform is the wrong type.
final class TestClock: Sendable {
    private let seconds: Mutex<Int64>

    init(startingAt seconds: Int64 = 1_700_000_000) {
        self.seconds = Mutex(seconds)
    }

    var now: Int64 { seconds.withLock { $0 } }

    func advance(by interval: Int64) {
        seconds.withLock { $0 += interval }
    }
}

extension MailStore {
    /// The two counts most assertions are really about, without a second query type.
    func counts(accountId: Int64 = 1) async throws -> MirrorProgress {
        try await mirrorProgress(accountId: accountId)
    }

    /// A mailbox by the id the fixtures and the routes use — the server's, not the
    /// mirror's. Keeping the two apart is the point of ADR-0033, so a test that means one
    /// has to say which.
    func mailbox(remoteId: Int64, accountId: Int64 = 1) async throws -> MailboxRecord? {
        try await mailboxes(accountId: accountId).first { $0.remoteId == remoteId }
    }

    /// A message by the server's id, for an assertion about something a recording contains.
    func message(remoteId: Int64, accountId: Int64 = 1) async throws -> MessageRecord? {
        let mailboxIds = Set(try await mailboxes(accountId: accountId).map(\.id))
        for mailboxId in mailboxIds.sorted() {
            let rows = try await messages(mailboxId: mailboxId, view: .flat, range: 0..<10_000)
            if let row = rows.first(where: { $0.remoteId == remoteId }) {
                return try await message(id: row.id)
            }
        }
        return nil
    }
}

extension FakeTransport {
    /// Paths of every request sent, for "it never asked about the unsubscribed folder".
    var requestPaths: [String] {
        requests.compactMap { $0.url?.path }
    }

    var requestURLs: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }
}
