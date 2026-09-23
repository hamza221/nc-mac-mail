// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB
import NCMailNet
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailStore
@testable import NCMailSync

/// **This file is the DAO `NCMailStore` is missing, written where WS-06 is allowed to write
/// it.**
///
/// `MailStore.read` and `MailStore.write` became internal in
/// [ADR-0034](../../../../../docs/decisions/0034-the-store-returns-its-own-sequence.md), and
/// `NCMailStore` has no queries over `pendingOperation`. So the production queue talks to
/// ``OperationStoring`` and this conformance — reachable from a test target through
/// `@testable`, and from nowhere else — is what runs every test below against the real
/// schema, the real transactions and the real GRDB.
///
/// [ADR-0043](../../../../../docs/decisions/0043-the-queue-names-the-storage-it-needs.md)
/// names the move: these eight methods become
/// `Packages/NCMailStore/Sources/NCMailStore/Queries/MailStore+Operations.swift`,
/// ``LocalEffect`` and ``MessageFlagColumns`` move down beside them, and `OperationStoring`
/// disappears because `MailStore` simply has the methods. Until WS-03 does that, the queue
/// cannot be wired into the app — which is the one thing this workstream could not finish
/// inside its own boundary.
struct MailStoreOperations: OperationStoring {
    let store: MailStore

    @discardableResult
    func enqueue(
        _ operations: [PendingOperationRecord],
        applying effects: [LocalEffect]
    ) async throws -> [Int64] {
        // ONE transaction, and the whole of ADR-0005: the local change and the promise to
        // send it commit together or not at all.
        try await store.write { db in
            var ids: [Int64] = []
            for (index, operation) in operations.enumerated() {
                if index < effects.count { try Self.apply(effects[index], in: db) }
                var row = operation
                try row.insert(db)
                if let id = row.id { ids.append(id) }
            }
            return ids
        }
    }

    func pendingOperations(accountId: Int64) async throws -> [PendingOperationRecord] {
        try await store.read { db in
            try PendingOperationRecord.fetchAll(
                db,
                sql: "SELECT * FROM pendingOperation WHERE accountId = ? ORDER BY id",
                arguments: [accountId]
            )
        }
    }

    func markInFlight(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await store.write { db in
            try db.execute(
                sql: """
                    UPDATE pendingOperation SET state = 'inFlight'
                     WHERE id IN \(questionMarks(count: ids.count))
                    """,
                arguments: StatementArguments(ids)
            )
        }
    }

    func reschedule(ids: [Int64], attempts: Int?, nextAttemptAt: Int64?, lastError: String?) async throws {
        guard !ids.isEmpty else { return }
        try await store.write { db in
            let arguments: [(any DatabaseValueConvertible)?] =
                [attempts, nextAttemptAt, lastError] + ids.map { $0 as (any DatabaseValueConvertible)? }
            try db.execute(
                sql: """
                    UPDATE pendingOperation
                       SET state = 'pending',
                           attempts = coalesce(?, attempts),
                           nextAttemptAt = ?,
                           lastError = ?
                     WHERE id IN \(questionMarks(count: ids.count))
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    func finish(ids: [Int64], applying effects: [LocalEffect]) async throws {
        try await store.write { db in
            for effect in effects { try Self.apply(effect, in: db) }
            guard !ids.isEmpty else { return }
            try db.execute(
                sql: "DELETE FROM pendingOperation WHERE id IN \(questionMarks(count: ids.count))",
                arguments: StatementArguments(ids)
            )
        }
    }

    func threadMessages(accountId: Int64, rootId: String) async throws -> [MessageRecord] {
        try await store.read { db in
            try MessageRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM message
                     WHERE accountId = ? AND threadRootId = ?
                     ORDER BY sentAt ASC, id ASC
                    """,
                arguments: [accountId, rootId]
            )
        }
    }

    /// One local effect, as SQL. Column names are looked up rather than interpolated from the
    /// payload, so a key nobody modelled cannot reach the statement.
    private static func apply(_ effect: LocalEffect, in db: Database) throws {
        guard !effect.messageIds.isEmpty else { return }
        let placeholders = questionMarks(count: effect.messageIds.count)

        if effect.removesRows {
            try db.execute(
                sql: "DELETE FROM message WHERE id IN \(placeholders)",
                arguments: StatementArguments(effect.messageIds)
            )
            return
        }

        var assignments: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []
        for key in effect.flags.keys.sorted() {
            guard let column = MessageFlagColumns.column(for: key) else { continue }
            assignments.append("\(column) = ?")
            values.append(effect.flags[key])
        }
        if let mailboxId = effect.mailboxId {
            assignments.append("mailboxId = ?")
            values.append(mailboxId)
        }
        guard !assignments.isEmpty else { return }
        values.append(contentsOf: effect.messageIds.map { $0 as (any DatabaseValueConvertible)? })
        try db.execute(
            sql: "UPDATE message SET \(assignments.joined(separator: ", ")) WHERE id IN \(placeholders)",
            arguments: StatementArguments(values)
        )
    }
}

/// The four methods `MailStore` already has, forwarded.
///
/// They are in the protocol because the queue needs them and a single port is easier to
/// reason about than "these from the store, those from somewhere else". When the DAO lands,
/// the protocol goes and these four forwardings go with it.
extension MailStoreOperations {
    func message(id: Int64) async throws -> MessageRecord? {
        try await store.message(id: id)
    }

    func mailbox(id: Int64) async throws -> MailboxRecord? {
        try await store.mailbox(id: id)
    }

    func mailboxes(accountId: Int64) async throws -> [MailboxRecord] {
        try await store.mailboxes(accountId: accountId)
    }

    func account(id: Int64) async throws -> AccountRecord? {
        try await store.account(id: id)
    }
}

/// `(?, ?, ?)` for an `IN` clause.
///
/// `NCMailStore` has this function already, and `@testable` will not resolve it from here —
/// the compiler answers "failed to produce diagnostic" rather than finding it, which is
/// reported in `library-feedback.md`. Three lines is cheaper than the workaround.
private func questionMarks(count: Int) -> String {
    "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
}

/// The wiring every queue test repeats: a mirror with an inbox, an archive, a trash and a
/// junk folder, a client pointed at a fake, and a clock the test owns.
enum QueueTest {
    struct Fixture {
        var store: MailStore
        var operations: MailStoreOperations
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
            try await operations.pendingOperations(accountId: accountId)
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
        let operations = MailStoreOperations(store: store)
        let drainer = OperationDrainer(
            store: operations,
            client: try MirrorTest.client(transport),
            accountId: seed.accountId,
            configuration: configuration
        )
        return Fixture(
            store: store,
            operations: operations,
            // No drainer: every test here says when a drain happens, so "queued but not sent"
            // is a state a test can stand in rather than a race it has to win.
            queue: MutationQueue(store: operations, drainer: nil, configuration: configuration),
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
