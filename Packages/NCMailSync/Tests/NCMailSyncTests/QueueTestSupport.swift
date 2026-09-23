// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// The wiring every queue test repeats: a mirror with an inbox, an archive, a trash and a
/// junk folder, a client pointed at a fake, and a clock the test owns.
///
/// The store is the real `MailStore`, so every test below runs against the real schema, the
/// real transactions and real GRDB. It used to be a protocol conformance written in this
/// file, because `NCMailStore` had no queue DAO and `read`/`write` are internal
/// ([ADR-0043](../../../../../docs/decisions/0043-the-queue-names-the-storage-it-needs.md));
/// the DAO is `MailStore+Operations.swift` now and the protocol is gone.
enum QueueTest {
    struct Fixture {
        var store: MailStore
        var queue: MutationQueue
        var drainer: OperationDrainer
        var transport: FakeTransport
        var clock: TestClock
        var accountId: Int64
        var inboxId: Int64
        var archiveId: Int64
        var trashId: Int64
        var junkId: Int64
        /// Local ids, oldest first. `MailStoreFixtures` numbers the server ids 1...n in the
        /// same order, which is what the request assertions rely on.
        var messageIds: [Int64]
        /// Mailboxes the drainer was asked to re-sync, and accounts it asked to re-read.
        var forcedSyncs: Recorder
        var accountRefreshes: Recorder

        func message(_ index: Int) async throws -> MessageRecord {
            try #require(try await store.message(id: messageIds[index]))
        }

        func rows() async throws -> [PendingOperationRecord] {
            try await store.pendingOperations(accountId: accountId)
        }
    }

    /// Server ids for the three folders the special roles name. Deliberately nothing like the
    /// local ids the mirror will assign, so a test that confuses the two fails.
    static let remoteArchive: Int64 = 920
    static let remoteTrash: Int64 = 921
    static let remoteJunk: Int64 = 922

    static func make(messages: Int = 12, threadSize: Int = 3, url: URL? = nil) async throws -> Fixture {
        let store = try url.map { try MailStore(url: $0) } ?? MailStore.inMemory()
        let seed = try await MailStoreFixtures.seed(store, messages: messages, threadSize: threadSize)
        let folders = try await store.upsert(
            mailboxes: [
                folder(accountId: seed.accountId, remoteId: remoteArchive, name: "Archive", role: "archive"),
                folder(accountId: seed.accountId, remoteId: remoteTrash, name: "Trash", role: "trash"),
                folder(accountId: seed.accountId, remoteId: remoteJunk, name: "Junk", role: "junk"),
            ],
            accountId: seed.accountId
        )
        // The account's special-mailbox columns hold the *server's* numbers, straight out of
        // the accounts payload. That is the trap `MutationQueue.localMailboxId` exists for.
        try await store.upsert(
            accounts: [
                AccountWrite(
                    identity: MailStoreFixtures.identity,
                    remoteId: seed.remoteAccountId,
                    name: "Fixture account",
                    emailAddress: "fixtures@example.invalid",
                    trashMailboxId: remoteTrash,
                    archiveMailboxId: remoteArchive,
                    junkMailboxId: remoteJunk
                )
            ]
        )

        let clock = TestClock()
        let forcedSyncs = Recorder()
        let accountRefreshes = Recorder()
        let configuration = MutationQueueConfiguration(
            // Short and distinct, so a test can say which step of the ladder it is on without
            // waiting for it.
            backoffSeconds: [2, 8, 30, 120, 600],
            now: { clock.now },
            forceSync: { mailboxId in forcedSyncs.record(mailboxId) },
            refreshAccount: { accountId in accountRefreshes.record(accountId) }
        )

        let transport = FakeTransport()
        let drainer = OperationDrainer(
            store: store,
            client: try MirrorTest.client(transport),
            accountId: seed.accountId,
            configuration: configuration
        )
        return Fixture(
            store: store,
            // No drainer: every test here says when a drain happens, so "queued but not sent"
            // is a state a test can stand in rather than a race it has to win.
            queue: MutationQueue(store: store, drainer: nil, configuration: configuration),
            drainer: drainer,
            transport: transport,
            clock: clock,
            accountId: seed.accountId,
            inboxId: seed.mailboxId,
            archiveId: try #require(folders.first { $0.remoteId == remoteArchive }).id,
            trashId: try #require(folders.first { $0.remoteId == remoteTrash }).id,
            junkId: try #require(folders.first { $0.remoteId == remoteJunk }).id,
            messageIds: seed.messageIds,
            forcedSyncs: forcedSyncs,
            accountRefreshes: accountRefreshes
        )
    }

    private static func folder(accountId: Int64, remoteId: Int64, name: String, role: String) -> MailboxWrite {
        MailboxWrite(
            accountId: accountId,
            remoteId: remoteId,
            name: name,
            displayName: name,
            specialRole: role,
            isSubscribed: true,
            unreadCount: 0
        )
    }

    // MARK: - Routes

    static let flagsRoute = RequestMatcher.method("PUT") && RequestMatcher.pathSuffix("/flags")
    static let moveRoute = RequestMatcher.method("POST") && RequestMatcher.pathSuffix("/move")
    static let deleteRoute = RequestMatcher.method("DELETE") && RequestMatcher.pathContains("/messages/")
    static let moveThreadRoute = RequestMatcher.method("POST") && RequestMatcher.pathContains("/thread/")
    static let deleteThreadRoute = RequestMatcher.method("DELETE") && RequestMatcher.pathContains("/thread/")

    /// Every mutation route answered with an empty 200, which is what the live server sends.
    static func stubEverything(_ transport: FakeTransport) async {
        for route in [flagsRoute, moveRoute, deleteRoute, moveThreadRoute, deleteThreadRoute] {
            await transport.stub(route, with: .status(200))
        }
    }

    /// The JSON body of a recorded request, for the tests about what was actually sent.
    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Writes a measurement where the test log shows it.
///
/// `print` is banned here because a mail body must never reach stdout. A count and a duration
/// are neither, and the brief asks for the number, so it goes to stderr explicitly.
func reportQueueMeasurement(_ text: String) {
    FileHandle.standardError.write(Data(("  [measured] " + text + "\n").utf8))
}

/// Ids a configuration callback was handed, readable from a synchronous assertion.
///
/// `Mutex` rather than an actor for that reason, and a class because `Mutex` is non-copyable
/// and a struct cannot hold one.
final class Recorder: Sendable {
    private let values = Mutex<[Int64]>([])

    func record(_ value: Int64) {
        values.withLock { $0.append(value) }
    }

    var all: [Int64] { values.withLock { $0 } }
}
