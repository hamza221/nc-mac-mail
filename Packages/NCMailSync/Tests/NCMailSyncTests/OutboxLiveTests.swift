// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Synchronization
import Testing

@testable import NCMailSync

/// WS-23's acceptance against a live server. Off by default, never part of `make test`.
///
/// Every message goes to the account's **own** address (ADR-0080), carries a unique token in
/// its subject, and is cleaned up by the test. Real timings: the undo window is the shipped
/// 10 s, so a full run takes about a minute.
///
/// ```
/// NCMAIL_LIVE_SYNC=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter OutboxLiveTests
/// ```
@Suite("Outbox against a live server", .serialized)
struct OutboxLiveTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_SYNC"]

    enum LiveError: Error { case missingEnvironment, noAccount }

    struct Live {
        var store: MailStore
        var client: MailClient
        var transport: OutboxCountingTransport
        var accountId: Int64
        var ownAddress: String
        var remoteSent: Int64
        var remoteDrafts: Int64
        var synced: OutboxRecorder

        func sender(store override: MailStore? = nil) -> OutboxSender {
            let client = client
            let store = override ?? store
            let accountId = accountId
            let synced = synced
            return OutboxSender(
                store: store,
                client: client,
                accountId: accountId,
                configuration: OutboxConfiguration(
                    syncMailbox: { synced.record($0) },
                    // Stand-in for WS-21's `refreshOutbox()`: the same GET, the same replace.
                    refreshOutbox: {
                        await OutboxLiveTests.mirrorOutbox(client: client, store: store, accountId: accountId)
                    }
                )
            )
        }

        func makeDraft(subject: String, in store: MailStore? = nil) async throws -> Int64 {
            let store = store ?? self.store
            let now = Int64(Date().timeIntervalSince1970)
            let draft = try await store.insert(
                draft: DraftRecord(
                    accountId: accountId, subject: subject, bodyPlain: "WS-23 live acceptance.",
                    isHtml: false, createdAt: now, updatedAt: now
                )
            )
            let id = try #require(draft.id)
            try await store.replaceRecipients(
                [DraftRecipientRecord(draftId: id, kind: "to", position: 0, email: ownAddress)],
                draftId: id
            )
            return id
        }

        func outboxSubjects() async throws -> [String] {
            try await client.get(.outbox).data.messages.compactMap(\.value.subject)
        }

        /// Server ids of messages in `mailbox` whose subject has `token`, after a cache sync.
        func messages(in mailbox: Int64, token: String) async throws -> [Int] {
            _ = try? await client.post(.sync(mailboxId: Int(mailbox)))
            return try await client.get(.messages(mailboxId: Int(mailbox), filter: "subject:\(token)"))
                .filter { $0.value.subject?.contains(token) == true }
                .map(\.value.id)
        }

        /// Polls until `condition` holds or `timeout` passes; returns the seconds it took.
        func waitUntil(timeout: TimeInterval = 60, _ condition: () async throws -> Bool) async throws -> Double? {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if try await condition() { return Date().timeIntervalSince(start) }
                try await Task.sleep(for: .seconds(1))
            }
            return nil
        }
    }

    static func live(store url: URL? = nil) async throws -> Live {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_SYNC"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        let transport = OutboxCountingTransport()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            transport: transport,
            clientVersion: "ws23-live"
        )
        let account = try #require(try await client.get(.accounts).first?.value)
        guard let sent = account.sentMailboxId, let drafts = account.draftsMailboxId else { throw LiveError.noAccount }
        let store = try url.map { try MailStore(url: $0) } ?? MailStore.inMemory()
        let rows = try await store.upsert(
            accounts: [
                AccountWrite(
                    identity: ServerIdentity(serverURL: server, loginName: user),
                    remoteId: Int64(account.id), name: account.name, emailAddress: account.emailAddress,
                    draftsMailboxId: Int64(drafts), sentMailboxId: Int64(sent)
                )
            ]
        )
        let accountId = try #require(rows.first?.id)
        _ = try await store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: accountId, remoteId: Int64(sent), name: "Sent", displayName: "Sent",
                    specialRole: "sent", isSubscribed: true, unreadCount: 0
                ),
                MailboxWrite(
                    accountId: accountId, remoteId: Int64(drafts), name: "Drafts", displayName: "Drafts",
                    specialRole: "drafts", isSubscribed: true, unreadCount: 0
                ),
            ],
            accountId: accountId
        )
        return Live(
            store: store, client: client, transport: transport, accountId: accountId,
            ownAddress: account.emailAddress, remoteSent: Int64(sent), remoteDrafts: Int64(drafts),
            synced: OutboxRecorder()
        )
    }

    static func mirrorOutbox(client: MailClient, store: MailStore, accountId: Int64) async {
        guard let messages = try? await client.get(.outbox).data.messages else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let rows = messages.map { raw in
            OutboxMessageRecord(
                accountId: accountId, remoteId: Int64(raw.value.id), subject: raw.value.subject,
                sendAt: raw.value.sendAt.map(Int64.init), failed: raw.value.failed, syncedAt: now
            )
        }
        try? await store.replaceOutbox(rows, accountId: accountId)
    }

    static func token() -> String { "ws23-\(UUID().uuidString.prefix(8).lowercased())" }

    // MARK: - Acceptance

    @Test(.enabled(if: OutboxLiveTests.serverEnvironment != nil))
    func composeSendAppearsInSent() async throws {
        let live = try await Self.live()
        let sender = live.sender()
        let token = Self.token()
        let id = try await live.makeDraft(subject: "\(token) send")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(token).txt")
        try Data("WS-23 attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await live.store.insert(
            draftAttachment: DraftAttachmentRecord(
                draftId: id, fileName: "ws23.txt", mime: "text/plain", localPath: file.path)
        )

        // An autosave first, so the send has a server draft to clean up.
        await sender.saveDraft(id)
        await sender.settle()
        let serverDraft = try #require(try await live.store.draft(id: id)?.remoteId)

        let started = Date()
        try await sender.send(draftId: id, sendAt: nil)
        await sender.settle()
        let dispatched = Date().timeIntervalSince(started)
        #expect(try await live.store.draft(id: id) == nil)
        reportOutboxMeasurement(
            "send() to dispatch complete: \(String(format: "%.1f", dispatched)) s (10 s undo window)")
        reportOutboxMeasurement("requests after the window: \(await live.transport.log.suffix(4))")

        let inSent = try await live.waitUntil { try await !live.messages(in: live.remoteSent, token: token).isEmpty }
        #expect(inSent != nil)
        reportOutboxMeasurement(
            "visible in Sent \(inSent.map { String(format: "%.1f", $0) } ?? "never") s after dispatch")
        #expect(try await live.outboxSubjects().allSatisfy { !$0.contains(token) })

        // Draft cleanup: the server draft became the outbox message and went with it.
        do {
            _ = try await live.client.put(
                .updateDraft(id: Int(serverDraft)),
                body: ComposeMessageRequest(accountId: 1, subject: "probe")
            )
            Issue.record("server draft \(serverDraft) still exists after send")
        } catch MailError.notFound {}
        #expect(live.synced.all.count == 1)

        // Clean up: the sent copy and the copy that arrived in the inbox.
        for message in try await live.messages(in: live.remoteSent, token: token) {
            _ = try? await live.client.delete(.deleteMessage(id: message))
        }
    }

    @Test(.enabled(if: OutboxLiveTests.serverEnvironment != nil))
    func undoInsideTheWindowLeavesNoServerTrace() async throws {
        let live = try await Self.live()
        let sender = live.sender()
        let token = Self.token()
        let id = try await live.makeDraft(subject: "\(token) undo")
        let before = await live.transport.log.count

        try await sender.send(draftId: id, sendAt: nil)
        try await Task.sleep(for: .seconds(3))
        #expect(await sender.undoSend(draftId: id))
        try await Task.sleep(for: .seconds(12))
        await sender.settle()

        #expect(await live.transport.log.count == before)
        #expect(try await live.store.draft(id: id)?.sendState == nil)
        #expect(try await live.outboxSubjects().allSatisfy { !$0.contains(token) })
        #expect(try await live.messages(in: live.remoteDrafts, token: token).isEmpty)
        #expect(try await live.messages(in: live.remoteSent, token: token).isEmpty)
        try await live.store.deleteDraft(id: id)
    }

    @Test(.enabled(if: OutboxLiveTests.serverEnvironment != nil))
    func scheduledSendAppearsInTheMirroredOutbox() async throws {
        let live = try await Self.live()
        let sender = live.sender()
        let token = Self.token()
        let id = try await live.makeDraft(subject: "\(token) scheduled")
        let when = Date().addingTimeInterval(86_400)

        try await sender.send(draftId: id, sendAt: when)
        await sender.settle()

        let mirrored = try await live.store.outboxMessages().filter { $0.subject?.contains(token) == true }
        #expect(mirrored.count == 1)
        #expect(mirrored.first?.sendAt == Int64(when.timeIntervalSince1970))
        let outboxId = try #require(mirrored.first?.id)

        try await sender.deleteOutbox(outboxId: outboxId)
        #expect(try await live.outboxSubjects().allSatisfy { !$0.contains(token) })
        #expect(try await live.store.outboxMessages().allSatisfy { $0.subject?.contains(token) != true })
    }

    @Test(.enabled(if: OutboxLiveTests.serverEnvironment != nil))
    func sendingADraftFromTheDraftsFolderExpungesIt() async throws {
        let live = try await Self.live()
        let sender = live.sender()
        let token = Self.token()
        let first = try await live.makeDraft(subject: "\(token) imap draft")
        await sender.closeDraft(first)
        #expect(try await live.store.draft(id: first) == nil)
        var imapDraft: Int?
        _ = try await live.waitUntil {
            imapDraft = try await live.messages(in: live.remoteDrafts, token: token).first
            return imapDraft != nil
        }
        let messageId = try #require(imapDraft)

        // Reopened from Drafts and sent: the composer names the IMAP copy it supersedes.
        let reopened = try await live.makeDraft(subject: "\(token) imap draft")
        var row = try #require(try await live.store.draft(id: reopened))
        row.replacesMessageId = Int64(messageId)
        try await live.store.update(draft: row)
        try await sender.send(draftId: reopened, sendAt: nil)
        await sender.settle()

        let gone = try await live.waitUntil { try await live.messages(in: live.remoteDrafts, token: token).isEmpty }
        #expect(gone != nil)
        for message in try await live.messages(in: live.remoteSent, token: token) {
            _ = try? await live.client.delete(.deleteMessage(id: message))
        }
    }

    @Test(.enabled(if: OutboxLiveTests.serverEnvironment != nil))
    func aQuitInsideTheWindowResumesAfterRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws23-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = try await Self.live(store: url)
        let token = Self.token()
        let id = try await live.makeDraft(subject: "\(token) quit")

        let first = live.sender()
        try await first.send(draftId: id, sendAt: nil)
        await first.stop()  // the app quits 0 s into the window

        try await Task.sleep(for: .seconds(3))
        let early = live.sender(store: try MailStore(url: url))
        await early.start()
        #expect(try await live.store.draft(id: id)?.sendState == "undo")
        await early.stop()

        try await Task.sleep(for: .seconds(8))
        let late = live.sender(store: try MailStore(url: url))
        await late.start()
        await late.settle()
        #expect(try await live.store.draft(id: id) == nil)
        let inSent = try await live.waitUntil { try await !live.messages(in: live.remoteSent, token: token).isEmpty }
        #expect(inSent != nil)
        for message in try await live.messages(in: live.remoteSent, token: token) {
            _ = try? await live.client.delete(.deleteMessage(id: message))
        }
    }
}

/// Forwards to the real transport and keeps `METHOD /path` of every request, no bodies, no query.
actor OutboxCountingTransport: MailTransport {
    private let inner = URLSessionTransport()
    private(set) var log: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "")")
        return try await inner.send(request)
    }
}

/// A count or a duration, to stderr, where the brief's numbers are read from.
func reportOutboxMeasurement(_ text: String) {
    FileHandle.standardError.write(Data(("  [measured] " + text + "\n").utf8))
}
