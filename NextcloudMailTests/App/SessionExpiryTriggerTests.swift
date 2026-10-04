// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// A 401 in the middle of a session raises the same modal as one at launch, once per login
/// until it signs in again (WS-25; ux-spec.md, "Authentication lost (401) → modal").
@Suite("Session expiry trigger")
struct SessionExpiryTriggerTests {
    private func unauthorized(_ id: Int64, count: Int) -> MailboxSyncFailure {
        MailboxSyncFailure(id: id, syncFailureCount: count, lastSyncError: "unauthorized")
    }

    @Test("the first emission is a baseline: a stale 401 left in the rows raises nothing")
    func firstEmissionIsBaseline() {
        var trigger = SessionExpiryTrigger()
        let fired = [
            trigger.observe([unauthorized(10, count: 4)], accountId: 1, sessionId: "a"),
            trigger.observe([unauthorized(10, count: 4)], accountId: 1, sessionId: "a"),
        ]
        #expect(fired == [false, false])
    }

    @Test("a newly recorded 401 fires, and the retry storm after it does not")
    func fireOncePerLogin() {
        var trigger = SessionExpiryTrigger()
        let fired = [
            trigger.observe([], accountId: 1, sessionId: "a"),
            trigger.observe([], accountId: 2, sessionId: "a"),
            trigger.observe([unauthorized(10, count: 1)], accountId: 1, sessionId: "a"),
            trigger.observe([unauthorized(10, count: 2)], accountId: 1, sessionId: "a"),
            // A second account of the same login is the same password.
            trigger.observe([unauthorized(20, count: 1)], accountId: 2, sessionId: "a"),
        ]
        #expect(fired == [false, false, true, false, false])
    }

    @Test("ordinary failures never fire")
    func ordinaryFailuresStayOut() {
        var trigger = SessionExpiryTrigger()
        _ = trigger.observe([], accountId: 1, sessionId: "a")
        for error in ["forbidden", "notFound", "transport", "rateLimited", "server(503)", "primingDidNotFinish"] {
            let failure = MailboxSyncFailure(id: 10, syncFailureCount: 1, lastSyncError: error)
            let fired = trigger.observe([failure], accountId: 1, sessionId: "a")
            #expect(!fired, "\(error)")
            _ = trigger.observe([], accountId: 1, sessionId: "a")
        }
    }

    @Test("signing in again re-arms the login, and its stale rows are a fresh baseline")
    func resetRearms() {
        var trigger = SessionExpiryTrigger()
        _ = trigger.observe([], accountId: 1, sessionId: "a")
        let before = trigger.observe([unauthorized(10, count: 1)], accountId: 1, sessionId: "a")
        #expect(before)

        trigger.forget(accountId: 1)
        trigger.reset(sessionId: "a")
        let after = [
            trigger.observe([unauthorized(10, count: 1)], accountId: 1, sessionId: "a"),
            trigger.observe([unauthorized(10, count: 2)], accountId: 1, sessionId: "a"),
        ]
        #expect(after == [false, true])
    }

    @Test("discovery's 401 and a sync's share one modal per login; another login has its own")
    func discoveryAndSyncShareOneModal() {
        var trigger = SessionExpiryTrigger()
        let fired = [
            trigger.fire(sessionId: "a"),
            trigger.observe([], accountId: 1, sessionId: "a"),
            trigger.observe([unauthorized(10, count: 1)], accountId: 1, sessionId: "a"),
            trigger.fire(sessionId: "b"),
        ]
        #expect(fired == [true, false, false, true])
    }

    @Test("the predicate the Get info panel shares")
    func predicate() {
        #expect(SessionExpiryTrigger.isAuthenticationLost("unauthorized"))
        #expect(!SessionExpiryTrigger.isAuthenticationLost("forbidden"))
        #expect(!SessionExpiryTrigger.isAuthenticationLost(nil))
    }
}

/// The trigger wired into ``AccountEngine``: a 401 recorded by a running account's sync.
@Suite("AccountEngine session expiry")
@MainActor
struct AccountEngineSessionExpiryTests {
    let store: MailStore
    let log = EventLog()
    let session = AccountSession(
        server: URL(string: "https://cloud.example.com")!,
        credentials: BasicCredentials(loginName: "alice", appPassword: "secret")
    )

    init() throws {
        store = try MailStore.inMemory()
    }

    private func mailbox() async throws -> (account: AccountRecord, mailbox: MailboxRecord) {
        let account = try #require(
            try await store.upsert(accounts: [
                AccountWrite(identity: session.identity, remoteId: 1, name: "Alice", emailAddress: "alice@example.com")
            ]).first
        )
        let write = MailboxWrite(
            accountId: account.id, remoteId: 5, name: "INBOX", delimiter: "/", displayName: "INBOX",
            specialRole: "inbox", isSubscribed: true, isSelectable: true, unreadCount: 0
        )
        let mailbox = try #require(try await store.upsert(mailboxes: [write], accountId: account.id).first)
        return (account, mailbox)
    }

    /// Records 401s until the modal is raised. The observation's first emission is its
    /// baseline and lands on its own schedule, so a single write could be taken for it.
    private func storm(_ mailboxId: Int64, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await store.recordSyncFailure(mailboxId: mailboxId, message: "unauthorized")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "the modal was never raised")
    }

    @Test("a revoked password mid-session raises the modal once, and again only after signing in")
    func midSessionUnauthorized() async throws {
        let (account, mailbox) = try await mailbox()
        let engine = AccountEngine(
            store: store,
            status: AppStatus(),
            factory: AccountEngineLifecycleTests.fakeFactory(log: log, builds: BuildLog())
        )
        defer { engine.stopAll() }
        var raised: [String] = []
        engine.sessionExpired = { raised.append($0.id) }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }

        try await storm(mailbox.id) { !raised.isEmpty }
        for _ in 0..<5 {
            try await store.recordSyncFailure(mailboxId: mailbox.id, message: "unauthorized")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(raised == [session.id])

        // Signing in again: the stale column is not news, the next 401 is.
        engine.add(session)
        try await log.waitUntil { events in events.filter { $0 == "\(account.id):outbox start" }.count == 2 }
        try await storm(mailbox.id) { raised.count == 2 }
    }

    @Test("an ordinary sync failure raises nothing")
    func ordinaryFailure() async throws {
        let (account, mailbox) = try await mailbox()
        let engine = AccountEngine(
            store: store,
            status: AppStatus(),
            factory: AccountEngineLifecycleTests.fakeFactory(log: log, builds: BuildLog())
        )
        defer { engine.stopAll() }
        var raised = 0
        engine.sessionExpired = { _ in raised += 1 }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }

        for _ in 0..<10 {
            try await store.recordSyncFailure(mailboxId: mailbox.id, message: "transport")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(raised == 0)
    }
}
