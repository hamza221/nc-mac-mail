// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// The message view against a real mirror.
///
/// Every test here seeds an in-memory `MailStore` with the recorded envelope for message
/// 166 and, where a body is wanted, the recorded HTML for the same message. Nothing is
/// mocked below the store, so "the view updates because the database changed" is asserted
/// rather than described.
@Suite("Message view model")
@MainActor
struct MessageViewModelTests {
    /// Records what the view asked the backfill for, and gives back nothing — which is the
    /// whole shape of `prioritise`.
    actor RecordingPrioritiser: BodyPrioritising {
        private(set) var calls: [Int64] = []

        func prioritise(messageId: Int64) async {
            calls.append(messageId)
        }
    }

    struct Mirror {
        var store: MailStore
        var model: MessageViewModel
        var prioritiser: RecordingPrioritiser
        var messageId: Int64
        var mailboxId: Int64
        var threadRootId: String
    }

    private static let server = "http://cloud.example.com"

    /// The recorded envelope for message 166, which is the same message
    /// `message-html-plain.html` is the body of.
    private static func recordedEnvelope() throws -> (json: String, remoteId: Int64, threadRootId: String) {
        let page = try JSONSerialization.jsonObject(with: try FixtureBytes.data("messages-inbox-page1.json"))
        let envelopes = try #require(page as? [[String: Any]])
        let envelope = try #require(envelopes.first { ($0["databaseId"] as? Int) == 166 })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        return (json, 166, try #require(envelope["threadRootId"] as? String))
    }

    private static func recordedHTML() throws -> String {
        String(decoding: try FixtureBytes.data("message-html-plain.html"), as: UTF8.self)
    }

    private static func seed(bodyState: BodyState = .missing) async throws -> Mirror {
        let store = try MailStore.inMemory()
        let identity = ServerIdentity(serverURL: server, loginName: "lorelai")
        let accounts = try await store.upsert(accounts: [
            AccountWrite(identity: identity, remoteId: 1, name: "Work", emailAddress: "lorelai@example.com")
        ])
        let accountId = try #require(accounts.first).id
        let mailboxes = try await store.upsert(
            mailboxes: [MailboxWrite(accountId: accountId, remoteId: 5, name: "INBOX", displayName: "Inbox")],
            accountId: accountId
        )
        let mailboxId = try #require(mailboxes.first).id

        let recorded = try recordedEnvelope()
        let ids = try await store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: recorded.remoteId,
                mailboxId: mailboxId,
                accountId: accountId,
                sentAt: 1_789_920_932,
                syncedAt: 1_789_920_999,
                messageId: recorded.threadRootId,
                threadRootId: recorded.threadRootId,
                subject: "Subject redacted",
                fromEmail: "user@example.com",
                fromLabel: "Name redacted",
                rawJSON: recorded.json
            )
        ])
        let messageId = try #require(ids.first)
        if bodyState != .missing {
            try await store.setBodyState(bodyState, messageIds: [messageId])
        }

        let prioritiser = RecordingPrioritiser()
        let model = MessageViewModel(
            services: MessageViewServices(
                store: store,
                client: MailClient(
                    server: try #require(URL(string: server)),
                    credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
                    transport: ReplayTransport.answering(status: 200)
                ),
                server: try #require(URL(string: server)),
                prioritiser: prioritiser
            )
        )
        return Mirror(
            store: store,
            model: model,
            prioritiser: prioritiser,
            messageId: messageId,
            mailboxId: mailboxId,
            threadRootId: recorded.threadRootId
        )
    }

    private static func storeBody(_ mirror: Mirror, html: String? = nil, plain: String? = nil) async throws {
        try await mirror.store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1_789_921_000,
                hasHtmlBody: html != nil,
                html: html,
                plainBody: plain,
                attachments: [
                    AttachmentWrite(
                        attachmentId: "2",
                        isInline: true,
                        fileName: "logo.png",
                        mime: "image/png",
                        size: 12,
                        cid: "logo",
                        isImage: true
                    )
                ]
            ),
            for: mirror.messageId
        )
    }

    /// Spins the main actor until `condition` holds.
    ///
    /// Not a sleep and not a clock read: the store delivers observation values on the main
    /// actor, so yielding is exactly what lets a pending delivery run. The bound is a
    /// failure, not a timeout.
    private static func waitUntil(_ condition: @MainActor () async -> Bool, limit: Int = 20_000) async -> Bool {
        for _ in 0..<limit {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    // MARK: - The envelope is always there

    @Test("the header is on screen before the body exists")
    func headerComesFirst() async throws {
        let mirror = try await Self.seed()
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.header != nil })
        let header = try #require(mirror.model.header)
        #expect(header.subject == "Subject redacted")
        #expect(header.sender?.email == "user@example.com")
        // Decoded out of the recorded envelope in `message.rawJSON`, because the store has no
        // reader for `messageAddress`.
        #expect(header.to.count == 1)
        #expect(mirror.model.presentation == .waiting)
    }

    @Test("opening a message that has no body raises its priority and waits for the database")
    func openingPrioritisesRatherThanFetching() async throws {
        let mirror = try await Self.seed()
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.header != nil })
        #expect(await Self.waitUntil { await mirror.prioritiser.calls == [mirror.messageId] })
        #expect(mirror.model.presentation == .waiting)
    }

    @Test("a body that is already mirrored is not asked for again")
    func presentBodiesAreNotPrioritised() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, plain: "Hello.")
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })
        #expect(await mirror.prioritiser.calls.isEmpty)
    }

    // MARK: - The invariant

    @Test("the body appears because the mirror changed, not because a view fetched it")
    func theViewUpdatesFromTheDatabase() async throws {
        let mirror = try await Self.seed()
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.header != nil })
        #expect(mirror.model.presentation == .waiting)

        // What the backfill does when `prioritise` reaches the front of the queue.
        try await Self.storeBody(mirror, html: try Self.recordedHTML())

        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })
        guard case .html(let rendered, let context) = mirror.model.presentation else {
            Issue.record("expected the HTML renderer, got \(mirror.model.presentation)")
            return
        }
        #expect(rendered.hasBlockedRemoteContent)
        #expect(context.localMessageId == mirror.messageId)
        #expect(context.remoteMessageId == 166)
    }

    @Test("the body write is what the observation the view is already on reports")
    func theBodyWriteTicksTheObservation() async throws {
        let mirror = try await Self.seed()
        var iterator = mirror.store
            .observeThread(rootId: mirror.threadRootId, mailboxId: mirror.mailboxId)
            .makeAsyncIterator()

        let before = try await iterator.next()
        #expect(before?.first?.bodyState == .missing)

        try await Self.storeBody(mirror, plain: "Hello.")

        // `upsert(body:for:)` sets `message.bodyState` in the same transaction as the body,
        // so this value arrives exactly when the body lands. It is the signal the message
        // view rides until `MailStore` gains `observeBody(messageId:)`.
        let after = try await iterator.next()
        #expect(after?.first?.bodyState == .present)
    }

    // MARK: - Remote content

    @Test("a mirrored body renders blocked, and show images re-renders it from the same HTML")
    func showImagesRerendersWithoutFetching() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, html: try Self.recordedHTML())
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })
        guard case .html(let blocked, let blockedContext) = mirror.model.presentation else {
            Issue.record("expected the HTML renderer")
            return
        }
        #expect(blocked.remoteImagesShown == 0)
        #expect(blockedContext.showsRemoteImages == false)
        #expect(mirror.model.hasBlockedRemoteContent)

        mirror.model.showImages()
        #expect(
            await Self.waitUntil {
                guard case .html(let shown, _) = mirror.model.presentation else { return false }
                return shown.remoteImagesShown == 9
            }
        )
        guard case .html(_, let shownContext) = mirror.model.presentation else {
            Issue.record("expected the HTML renderer")
            return
        }
        #expect(shownContext.showsRemoteImages)
    }

    // MARK: - The other renderer, and the other states

    @Test("a plain body never reaches a web engine")
    func plainBodiesUseTheNativeRenderer() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, plain: "Hello, and https://example.com/x")
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })
        #expect(mirror.model.presentation == .plain(text: "Hello, and https://example.com/x", signature: nil))
        #expect(!mirror.model.hasBlockedRemoteContent)
    }

    @Test("a failed body offers a retry, and retrying asks the backfill again")
    func failedBodiesRetry() async throws {
        let mirror = try await Self.seed(bodyState: .failed)
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.presentation == .failed })
        mirror.model.retry()
        #expect(await Self.waitUntil { await mirror.prioritiser.calls.count == 2 })
    }

    @Test("selecting another message replaces the observation rather than adding one")
    func selectionReplacesTheObservation() async throws {
        let mirror = try await Self.seed()
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.header != nil })

        mirror.model.present(messageId: nil)
        #expect(mirror.model.header == nil)
        #expect(mirror.model.presentation == .waiting)

        // Whatever the mirror does now, nothing is listening for it.
        try await Self.storeBody(mirror, plain: "Hello.")
        #expect(mirror.model.presentation == .waiting)
    }

    @Test("the attachments of the open message come from the mirror")
    func attachmentsComeFromTheMirror() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, plain: "Hello.")
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { !mirror.model.attachments.isEmpty })
        let attachment = try #require(mirror.model.attachments.first)
        #expect(attachment.attachmentId == "2")
        #expect(attachment.mime == "image/png")
    }
}
