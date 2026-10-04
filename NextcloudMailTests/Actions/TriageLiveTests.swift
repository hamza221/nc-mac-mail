// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The brief's report questions, answered against the live server: an offline snooze on an
/// account with no snooze mailbox (createMailbox → patchAccount → snooze, all placeholders),
/// and an offline tag create-and-set, each reaching the server on one drain.
///
/// "Offline" is `MessageActions` with no drainer woken, exactly what the app has with no
/// route. Reconnecting is one `OperationDrainer.drain()`.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://localhost NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild test -project NextcloudMail.xcodeproj -scheme NextcloudMail \
///   -destination 'platform=macOS' -only-testing:NextcloudMailTests/TriageLiveTests
/// ```
@MainActor
@Suite("Triage against a live server", .serialized)
struct TriageLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }

    enum LiveError: Error { case missingEnvironment }

    private struct Live {
        let store: MailStore
        let client: MailClient
        let account: AccountRecord
        let inbox: MailboxRecord
        let drainer: OperationDrainer
    }

    private func connect() async throws -> Live {
        guard
            let raw = Self.environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = Self.environment["NCMAIL_LIVE_USER"],
            let password = Self.environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "triage-live-test")
        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store, client: client, identity: ServerIdentity(serverURL: server, loginName: user))
        let account = try #require(accounts.first)
        try await mirrorMailboxes(store: store, client: client, account: account)
        let inbox = try #require(
            try await store.mailboxes(accountId: account.id).first { $0.specialRole?.lowercased() == "inbox" })
        try await mirrorEnvelopes(store: store, client: client, account: account, mailbox: inbox)
        return Live(
            store: store, client: client, account: account, inbox: inbox,
            drainer: OperationDrainer(store: store, client: client, accountId: account.id))
    }

    private func mirrorMailboxes(store: MailStore, client: MailClient, account: AccountRecord) async throws {
        let list = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
        try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
            accountId: account.id)
    }

    @discardableResult
    private func mirrorEnvelopes(
        store: MailStore, client: MailClient, account: AccountRecord, mailbox: MailboxRecord
    ) async throws -> [RawBacked<Envelope>] {
        let page = try await Self.list(client, mailboxRemoteId: Int(mailbox.remoteId))
        try await store.upsert(
            envelopes: try page.map {
                try MirrorMapping.envelopeWrite($0, accountId: account.id, mailboxId: mailbox.id, syncedAt: 1)
            })
        return page
    }

    /// One page of a mailbox as the server sees it *now*: an initialising sync first, which
    /// both primes a freshly created Snoozed folder (it answers 428 until then) and makes the
    /// server's cache notice a move it made over IMAP.
    private static func list(_ client: MailClient, mailboxRemoteId: Int) async throws -> [RawBacked<Envelope>] {
        _ = try await client.post(.sync(mailboxId: mailboxRemoteId), body: SyncRequest(ids: [], initialise: true))
        return try await client.get(Endpoint.messages(mailboxId: mailboxRemoteId, limit: 100))
    }

    @Test(.enabled(if: TriageLiveTests.hasLiveServer))
    func offlineSnoozeCreatesTheFolderAndReachesTheServer() async throws {
        let live = try await connect()
        let actions = MessageActions(store: live.store)
        let message = try #require(
            try await live.store.messages(mailboxId: live.inbox.id, view: .flat, range: 0..<1).first)
        let record = try #require(try await live.store.message(id: message.id))
        let hadSnoozeMailbox = live.account.snoozeMailboxId != nil

        // Offline.
        await actions.snooze(Selection(messageIds: [record.id]), until: Int64(Date.now.timeIntervalSince1970) + 86_400)
        let kinds = try await live.store.pendingOperations(accountId: live.account.id).map(\.kind)
        if hadSnoozeMailbox {
            #expect(kinds == ["snooze"])
        } else {
            #expect(kinds.suffix(2) == ["patchAccount", "snooze"])
        }

        // Reconnect.
        let started = ContinuousClock.now
        await live.drainer.drain()
        // The whole chain is a handful of requests; the suite's duration line is the number.
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(try await live.store.pendingOperations(accountId: live.account.id).isEmpty)

        // The server agrees: the account names a snooze mailbox and the message is in it.
        let accounts = try await live.client.get(Endpoint.accounts)
        let snoozeRemote = try #require(
            accounts.first { Int64($0.value.id) == live.account.remoteId }?.value.snoozeMailboxId)
        let snoozed = try await Self.list(live.client, mailboxRemoteId: snoozeRemote)
        let moved = try #require(snoozed.first { $0.value.messageId == record.messageId })

        // Put it back: unsnooze on the server's new copy, offline, then drain.
        try await mirrorMailboxes(store: live.store, client: live.client, account: live.account)
        let snoozeMailbox = try #require(
            try await live.store.mailboxes(accountId: live.account.id).first { $0.remoteId == Int64(snoozeRemote) })
        try await mirrorEnvelopes(store: live.store, client: live.client, account: live.account, mailbox: snoozeMailbox)
        let copy = try #require(
            try await live.store.messages(mailboxId: snoozeMailbox.id, view: .flat, range: 0..<100)
                .first { $0.remoteId == Int64(moved.value.id) })
        await actions.unsnooze(Selection(messageIds: [copy.id]))
        await live.drainer.drain()
        #expect(try await live.store.pendingOperations(accountId: live.account.id).isEmpty)
        // The server moved it back over IMAP; `list` syncs its Inbox cache first.
        let inbox = try await Self.list(live.client, mailboxRemoteId: Int(live.inbox.remoteId))
        #expect(inbox.contains { $0.value.messageId == record.messageId })
    }

    @Test(.enabled(if: TriageLiveTests.hasLiveServer))
    func offlineTagCreateAndSetReachTheServer() async throws {
        let live = try await connect()
        let actions = MessageActions(store: live.store)
        let message = try #require(
            try await live.store.messages(mailboxId: live.inbox.id, view: .flat, range: 0..<1).first)
        let name = "WS31 Live \(UUID().uuidString.prefix(6))"

        await actions.createTag(accountId: live.account.id, displayName: name, color: TagRules.randomColor())
        let placeholder = try #require(
            try await live.store.tags(accountId: live.account.id).first { $0.displayName == name })
        await actions.setTag(placeholder, present: true, on: Selection(messageIds: [message.id]))

        let started = ContinuousClock.now
        await live.drainer.drain()
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(try await live.store.pendingOperations(accountId: live.account.id).isEmpty)

        let real = try #require(try await live.store.tags(accountId: live.account.id).first { $0.displayName == name })
        #expect(real.remoteId > 0)
        let envelope = try await live.client.get(Endpoint.message(id: Int(message.remoteId)))
        #expect(envelope.value.tags.values.contains { $0.displayName == name })

        // Clean up through the same path.
        await actions.deleteTag(real)
        await live.drainer.drain()
        let after = try await live.client.get(Endpoint.message(id: Int(message.remoteId)))
        #expect(!after.value.tags.values.contains { $0.displayName == name })
    }
}
