// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The `start-mailbox-id` preference, spelled as the web client spells it, saved through the
/// queue and read back at a launch with no local selection.
@Suite("Start mailbox")
@MainActor
struct StartMailboxTests {
    // MARK: - The mapping

    @Test("selections map to the web client's values")
    func values() {
        #expect(StartMailbox.value(for: .mailbox(5), remoteMailboxId: 77) == "77")
        #expect(StartMailbox.value(for: .unifiedInbox, remoteMailboxId: nil) == "unified")
        #expect(StartMailbox.value(for: .priorityInbox, remoteMailboxId: nil) == "priority")
        #expect(StartMailbox.value(for: .favorites(inboxId: 5), remoteMailboxId: 77) == nil)
        #expect(StartMailbox.value(for: .outbox, remoteMailboxId: nil) == nil)
        #expect(StartMailbox.value(for: .contacts(sessionId: "s", scope: .all), remoteMailboxId: nil) == nil)
    }

    @Test("values map back to selections, and a mailbox that is gone to none")
    func selections() {
        let local: (Int64) -> Int64? = { $0 == 77 ? 5 : nil }
        #expect(StartMailbox.selection(for: "77", localMailboxId: local) == .mailbox(5))
        #expect(StartMailbox.selection(for: "78", localMailboxId: local) == nil)
        #expect(StartMailbox.selection(for: "unified", localMailboxId: local) == .unifiedInbox)
        #expect(StartMailbox.selection(for: "priority", localMailboxId: local) == .priorityInbox)
        #expect(StartMailbox.selection(for: "", localMailboxId: local) == nil)
    }

    // MARK: - Saving and reading through the engine

    let store: MailStore
    let session = AccountSession(
        server: URL(string: "https://cloud.example.com")!,
        credentials: BasicCredentials(loginName: "alice", appPassword: "secret")
    )

    init() throws {
        store = try MailStore.inMemory()
    }

    private func mirror() async throws -> (account: AccountRecord, inbox: MailboxRecord, loginId: Int64) {
        let account = try #require(
            try await store.upsert(accounts: [
                AccountWrite(identity: session.identity, remoteId: 1, name: "Alice", emailAddress: "alice@example.com")
            ]).first
        )
        let inbox = try #require(
            try await store.upsert(
                mailboxes: [MailboxWrite(accountId: account.id, remoteId: 77, name: "INBOX", displayName: "Inbox")],
                accountId: account.id
            ).first
        )
        let loginId = try #require(try await store.ensureLogin(session.identity).id)
        return (account, inbox, loginId)
    }

    private func engine() -> AccountEngine {
        let engine = AccountEngine(
            store: store,
            status: AppStatus(),
            factory: AccountEngineLifecycleTests.fakeFactory(log: EventLog(), builds: BuildLog())
        )
        engine.start(accounts: [session])
        return engine
    }

    @Test("staying on a mailbox queues its server id as the start mailbox")
    func savingQueuesThePreference() async throws {
        let (account, inbox, loginId) = try await mirror()
        let engine = engine()
        defer { engine.stopAll() }

        await engine.saveStartMailbox(.mailbox(inbox.id))

        let queued = try await store.pendingOperations(accountId: account.id)
        #expect(queued.map(\.kind) == [OperationKind.setPreference.rawValue])
        #expect(try await store.preferenceValue(key: "start-mailbox-id", loginId: loginId) == "77")
    }

    @Test("Unified inbox is saved as the web client's 'unified'")
    func savingUnified() async throws {
        let (account, _, loginId) = try await mirror()
        let engine = engine()
        defer { engine.stopAll() }

        await engine.saveStartMailbox(.unifiedInbox)

        #expect(try await store.pendingOperations(accountId: account.id).count == 1)
        #expect(try await store.preferenceValue(key: "start-mailbox-id", loginId: loginId) == "unified")
    }

    @Test("a value the server already holds is not written again")
    func unchangedIsNotQueued() async throws {
        let (account, inbox, loginId) = try await mirror()
        try await store.setPreference(key: "start-mailbox-id", value: "77", loginId: loginId, fetchedAt: 0)
        let engine = engine()
        defer { engine.stopAll() }

        await engine.saveStartMailbox(.mailbox(inbox.id))

        #expect(try await store.pendingOperations(accountId: account.id).isEmpty)
    }

    @Test("a launch reads the mirrored preference back as a local selection")
    func readingResolvesToALocalMailbox() async throws {
        let (_, inbox, loginId) = try await mirror()
        let engine = engine()
        defer { engine.stopAll() }

        #expect(await engine.startMailbox() == nil)
        try await store.setPreference(key: "start-mailbox-id", value: "77", loginId: loginId, fetchedAt: 0)
        #expect(await engine.startMailbox() == .mailbox(inbox.id))
        try await store.setPreference(key: "start-mailbox-id", value: "999", loginId: loginId, fetchedAt: 0)
        #expect(await engine.startMailbox() == nil)
    }
}
