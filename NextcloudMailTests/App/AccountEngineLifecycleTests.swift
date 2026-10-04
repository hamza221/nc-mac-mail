// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// Every engine starts with sign-in and stops with sign-out, contacts included (WS-25).
///
/// The engines are fakes that log what they are told, built by an `EngineFactory` that also
/// logs what it built; discovery opens no socket. Account rows are written straight into an
/// in-memory mirror, which is what discovery would have done.
@Suite("AccountEngine lifecycle")
@MainActor
struct AccountEngineLifecycleTests {
    nonisolated static let loginParts = ["calendars", "contacts", "results", "serverState"]
    nonisolated static let accountParts = ["mirror", "scheduler", "avatars", "outbox"]

    let store: MailStore
    let log = EventLog()
    /// What the factory built, in order. Written synchronously by the factory, which runs on
    /// the main actor, so the order is the engine's and not a scheduler's.
    let builds = BuildLog()
    let session = AccountSession(
        server: URL(string: "https://cloud.example.com")!,
        credentials: BasicCredentials(loginName: "alice", appPassword: "secret")
    )

    init() throws {
        store = try MailStore.inMemory()
    }

    private func makeEngine() -> AccountEngine {
        AccountEngine(store: store, status: AppStatus(), factory: Self.fakeFactory(log: log, builds: builds))
    }

    @discardableResult
    private func addAccountRow(remoteId: Int64 = 1) async throws -> AccountRecord {
        let rows = try await store.upsert(accounts: [
            AccountWrite(
                identity: session.identity,
                remoteId: remoteId,
                name: "Alice \(remoteId)",
                emailAddress: "alice\(remoteId)@example.com"
            )
        ])
        return try #require(rows.first { $0.remoteId == remoteId })
    }

    // MARK: - Start

    @Test("signing in starts every login engine, then every account engine")
    func signInStartsEverything() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        defer { engine.stopAll() }

        engine.start(accounts: [session])

        let expected = Self.loginParts.map { "login:\($0)" } + Self.accountParts.map { "\(account.id):\($0)" }
        try await log.waitUntil { events in expected.allSatisfy { events.contains("\($0) start") } }

        // The login is built before any account: the scheduler and the outbox call into its
        // server-state mirror and the drainer sends through its contact handler.
        #expect(builds.names == ["login", "account \(account.id)"])
        #expect(engine.contactsQueue(sessionId: session.id) != nil)
        #expect(engine.settingsCommands(sessionId: session.id) != nil)
    }

    @Test("an account row that appears later starts against the running login")
    func lateRowStarts() async throws {
        let engine = makeEngine()
        defer { engine.stopAll() }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("login:serverState start") }

        let account = try await addAccountRow(remoteId: 2)
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }
        #expect(builds.names.filter { $0 == "login" }.count == 1)
    }

    // MARK: - Stop

    @Test("signing out stops every engine, accounts before the login")
    func signOutStopsEverything() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") && $0.contains("login:serverState start") }

        await engine.signOut(sessionId: session.id).value

        let events = await log.events
        let stops = events.filter { $0.hasSuffix(" stop") }
        let expected =
            Self.accountParts.reversed().map { "\(account.id):\($0) stop" }
            + Self.loginParts.reversed().map { "login:\($0) stop" }
        #expect(stops == expected)
        #expect(engine.account(id: account.id) == nil)
        #expect(engine.serverResults(sessionId: session.id) == nil)
        #expect(engine.contactsQueue(sessionId: session.id) == nil)
        #expect(engine.settingsCommands(sessionId: session.id) == nil)
    }

    @Test("after sign-out, a row for the same login starts nothing")
    func nothingSurvivesSignOut() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        defer { engine.stopAll() }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }
        await engine.signOut(sessionId: session.id).value
        let buildsBefore = builds.names.count

        try await addAccountRow(remoteId: 9)
        try await Task.sleep(for: .milliseconds(300))

        #expect(builds.names.count == buildsBefore)
    }

    @Test("signing out at once never leaves a part started after its stop")
    func signOutRacingStart() async throws {
        try await addAccountRow()
        let engine = makeEngine()
        engine.start(accounts: [session])
        while !builds.names.contains(where: { $0.hasPrefix("account") }) { await Task.yield() }

        await engine.signOut(sessionId: session.id).value

        let events = await log.events
        let parts = Set(
            events.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { $0.contains(":") })
        for part in parts {
            let last = events.last { $0.hasPrefix("\(part) start") || $0.hasPrefix("\(part) stop") }
            #expect(last == nil || last == "\(part) stop", "\(part) was left running")
        }
    }

    @Test("a deleted account row stops its account engines and leaves the login running")
    func deletedRowStopsOnlyItsAccount() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        defer { engine.stopAll() }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }

        try await store.deleteAccount(id: account.id)

        try await log.waitUntil { $0.contains("\(account.id):mirror stop") }
        #expect(await !log.events.contains { $0.hasPrefix("login:") && $0.hasSuffix(" stop") })
    }

    @Test("signing in again replaces the running login with one using the new password")
    func reSignInReplaces() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        defer { engine.stopAll() }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") }

        engine.add(session)

        try await log.waitUntil { events in events.filter { $0 == "\(account.id):outbox start" }.count == 2 }
        let events = await log.events
        #expect(events.contains("login:contacts stop"))
        #expect(builds.names.filter { $0 == "login" }.count == 2)
    }

    // MARK: - Conditions and wake

    @Test("network conditions reach every engine; a wake reaches the login's")
    func conditionsAndWake() async throws {
        let account = try await addAccountRow()
        let engine = makeEngine()
        defer { engine.stopAll() }
        engine.start(accounts: [session])
        try await log.waitUntil { $0.contains("\(account.id):outbox start") && $0.contains("login:serverState start") }

        engine.apply(conditions: NetworkConditions(isOffline: true, isExpensive: false, isConstrained: false))
        engine.systemDidWake()

        let offline =
            Self.loginParts.map { "login:\($0) offline" } + Self.accountParts.map { "\(account.id):\($0) offline" }
        try await log.waitUntil { events in offline.allSatisfy(events.contains) }
        try await log.waitUntil { events in Self.loginParts.allSatisfy { events.contains("login:\($0) wake") } }
        #expect(await !log.events.contains { $0.hasPrefix("\(account.id):") && $0.hasSuffix(" wake") })
    }

    // MARK: - Fakes

    static func fakeFactory(log: EventLog, builds: BuildLog) -> EngineFactory {
        EngineFactory(
            discover: { _, _ in },
            login: { _, _, _, _ in
                builds.names.append("login")
                return LoginEngines(parts: loginParts.map { FakePart(name: "login:\($0)", log: log) })
            },
            account: { _, row, _, _ in
                builds.names.append("account \(row.id)")
                return AccountEngines(parts: accountParts.map { FakePart(name: "\(row.id):\($0)", log: log) })
            }
        )
    }
}

/// What the fakes were told, in order.
actor EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    /// Polls until `condition` holds. The engine is fire-and-forget by design, so there is
    /// nothing to await directly; a condition that never holds fails rather than hangs.
    nonisolated func waitUntil(
        within seconds: Double = 5,
        _ condition: @Sendable ([String]) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition(await events) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out; events: \(await events)")
        throw CancellationError()
    }
}

nonisolated struct FakePart: EnginePart {
    let name: String
    let log: EventLog

    func engineStart() async { await log.record("\(name) start") }
    func engineStop() async { await log.record("\(name) stop") }
    func engineApply(_ conditions: MirrorConditions) async {
        if conditions.isOffline { await log.record("\(name) offline") }
    }
    func engineWake() async { await log.record("\(name) wake") }
}

/// The factory's builds, on the main actor like the factory itself.
final class BuildLog {
    var names: [String] = []
}
