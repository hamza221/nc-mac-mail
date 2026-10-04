// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// The wiring every outbox test repeats: an account with Sent and Drafts folders, a client
/// pointed at a fake, a clock the test owns, and recorders for the two hooks.
///
/// The clock is also the sleep: waiting `d` advances it by `d` and returns, so an undo window
/// "passes" instantly and deterministically. A test that needs a window to stay open passes
/// `sleepsForReal`, and the timer then only ends by cancellation.
enum OutboxTest {
    static let remoteSent: Int64 = 905
    static let remoteDrafts: Int64 = 902
    static let remoteAccount: Int64 = 1

    struct Fixture {
        var store: MailStore
        var sender: OutboxSender
        var client: MailClient
        var transport: FakeTransport
        var clock: OutboxClock
        var accountId: Int64
        var sentId: Int64
        var draftsId: Int64
        var syncedMailboxes: OutboxRecorder
        var outboxRefreshes: OutboxRecorder

        /// A draft with one recipient, as the composer would leave it.
        func makeDraft(subject: String = "Hello", to: String = "someone@example.invalid") async throws -> Int64 {
            let draft = try await store.insert(
                draft: DraftRecord(
                    accountId: accountId,
                    subject: subject,
                    bodyPlain: "Body",
                    isHtml: false,
                    createdAt: clock.seconds,
                    updatedAt: clock.seconds
                )
            )
            let id = try #require(draft.id)
            try await store.replaceRecipients(
                [DraftRecipientRecord(draftId: id, kind: "to", position: 0, email: to)],
                draftId: id
            )
            return id
        }

        func draft(_ id: Int64) async throws -> DraftRecord? {
            try await store.draft(id: id)
        }

        /// A second sender over the same store and transport: the app after a relaunch.
        func relaunched(sleepsForReal: Bool = false) -> OutboxSender {
            OutboxSender(
                store: store,
                client: client,
                accountId: accountId,
                configuration: OutboxTest.configuration(
                    clock: clock,
                    sleepsForReal: sleepsForReal,
                    synced: syncedMailboxes,
                    refreshes: outboxRefreshes
                )
            )
        }

        func paths() async -> [String] {
            await transport.requests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "")" }
        }
    }

    static func make(sleepsForReal: Bool = false, store url: URL? = nil) async throws -> Fixture {
        let store = try url.map { try MailStore(url: $0) } ?? MailStore.inMemory()
        let accounts = try await store.upsert(
            accounts: [
                AccountWrite(
                    identity: MailStoreFixtures.identity,
                    remoteId: remoteAccount,
                    name: "Fixture account",
                    emailAddress: "fixtures@example.invalid",
                    draftsMailboxId: remoteDrafts,
                    sentMailboxId: remoteSent
                )
            ]
        )
        let accountId = try #require(accounts.first?.id)
        let folders = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: accountId, remoteId: remoteSent, name: "Sent", displayName: "Sent",
                    specialRole: "sent", isSubscribed: true, unreadCount: 0
                ),
                MailboxWrite(
                    accountId: accountId, remoteId: remoteDrafts, name: "Drafts", displayName: "Drafts",
                    specialRole: "drafts", isSubscribed: true, unreadCount: 0
                ),
            ],
            accountId: accountId
        )
        let clock = OutboxClock()
        let synced = OutboxRecorder()
        let refreshes = OutboxRecorder()
        let transport = FakeTransport()
        let client = MailClient(
            server: try #require(URL(string: "https://fixtures.example.invalid")),
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport,
            retryPolicy: .none,
            clientVersion: "test"
        )
        let sender = OutboxSender(
            store: store,
            client: client,
            accountId: accountId,
            configuration: configuration(
                clock: clock,
                sleepsForReal: sleepsForReal,
                synced: synced,
                refreshes: refreshes
            )
        )
        return Fixture(
            store: store,
            sender: sender,
            client: client,
            transport: transport,
            clock: clock,
            accountId: accountId,
            sentId: try #require(folders.first { $0.remoteId == remoteSent }).id,
            draftsId: try #require(folders.first { $0.remoteId == remoteDrafts }).id,
            syncedMailboxes: synced,
            outboxRefreshes: refreshes
        )
    }

    static func configuration(
        clock: OutboxClock,
        sleepsForReal: Bool,
        synced: OutboxRecorder,
        refreshes: OutboxRecorder
    ) -> OutboxConfiguration {
        OutboxConfiguration(
            now: { Date(timeIntervalSince1970: TimeInterval(clock.seconds)) },
            sleep: { duration in
                if sleepsForReal {
                    try await Task.sleep(for: .seconds(3_600))
                } else {
                    try Task.checkCancellation()
                    clock.advance(by: duration.components.seconds)
                }
            },
            syncMailbox: { synced.record($0) },
            refreshOutbox: { refreshes.record(1) }
        )
    }

    // MARK: - Routes

    static let createDraft = RequestMatcher.method("POST") && RequestMatcher.pathSuffix("/api/drafts")
    static let updateDraft = RequestMatcher.method("PUT") && RequestMatcher.pathContains("/api/drafts/")
    static let deleteDraft = RequestMatcher.method("DELETE") && RequestMatcher.pathContains("/api/drafts/")
    static let moveDraft = RequestMatcher.method("POST") && RequestMatcher.pathContains("/api/drafts/move/")
    static let upload = RequestMatcher.method("POST") && RequestMatcher.pathSuffix("/api/attachments")
    static let fromDraft = RequestMatcher.method("POST") && RequestMatcher.pathContains("/api/outbox/from-draft/")
    static let sendOutbox = RequestMatcher.method("POST") && RequestMatcher.pathSuffix("/api/outbox/52")
    static let getOutbox = RequestMatcher.method("GET") && RequestMatcher.pathContains("/api/outbox/")
    static let deleteOutbox = RequestMatcher.method("DELETE") && RequestMatcher.pathContains("/api/outbox/")

    /// Every route answered as the live server answered it (recorded fixtures).
    static func stubHappyPath(_ transport: FakeTransport) async throws {
        // Order matters: `moveDraft` and `fromDraft` must win over the broader matchers.
        await transport.stub(moveDraft, with: try .fixture("draft-moved.json", status: 202))
        await transport.stub(fromDraft, with: try .fixture("outbox-from-draft.json", status: 201))
        await transport.stub(createDraft, with: try .fixture("draft-created.json", status: 201))
        await transport.stub(updateDraft, with: try .fixture("draft-updated.json", status: 202))
        await transport.stub(deleteDraft, with: try .fixture("draft-deleted.json", status: 202))
        await transport.stub(upload, with: try .fixture("attachment-uploaded.json", status: 201))
        await transport.stub(sendOutbox, with: try .fixture("outbox-sent.json", status: 202))
        await transport.stub(deleteOutbox, with: try .fixture("outbox-deleted.json", status: 202))
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Unix seconds the test owns.
final class OutboxClock: Sendable {
    private let value = Mutex<Int64>(1_800_000_000)
    var seconds: Int64 { value.withLock { $0 } }
    func advance(by interval: Int64) { value.withLock { $0 += interval } }
}

/// Values a hook was handed, readable from a synchronous assertion.
final class OutboxRecorder: Sendable {
    private let values = Mutex<[Int64]>([])
    func record(_ value: Int64) { values.withLock { $0.append(value) } }
    var all: [Int64] { values.withLock { $0 } }
}
