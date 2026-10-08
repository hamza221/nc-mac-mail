// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The message view against a real mirror.
///
/// Every test here seeds an in-memory `MailStore` with the recorded envelope of the
/// recorder's remote-images self-send and, where a body is wanted, the recorded HTML for the
/// same message. Nothing is
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
        var accountId: Int64
        var mailboxId: Int64
        var threadRootId: String
    }

    private static let server = "http://cloud.example.com"

    /// The recorded envelope of the message `message-html-remote-images.html` is the body of,
    /// recorded beside it.
    private static func recordedEnvelope() throws -> (
        json: String, remoteId: Int64, threadRootId: String, addresses: [EnvelopeAddress]
    ) {
        let object = try JSONSerialization.jsonObject(
            with: try FixtureBytes.data("message-remote-images-envelope.json")
        )
        let envelope = try #require(object as? [String: Any])
        let remoteId = Int64(try #require(envelope["databaseId"] as? Int))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)

        // The address rows the sync engine would have written, taken from the same recording
        // rather than typed in. `MirrorMapping.envelopeWrite` does this for real.
        var addresses: [EnvelopeAddress] = []
        for (key, kind) in [("from", AddressKind.from), ("to", .to), ("cc", .cc)] {
            for entry in (envelope[key] as? [[String: Any]]) ?? [] {
                guard let email = entry["email"] as? String else { continue }
                addresses.append(EnvelopeAddress(kind: kind, email: email, label: entry["label"] as? String))
            }
        }
        return (json, remoteId, try #require(envelope["threadRootId"] as? String), addresses)
    }

    private static func recordedHTML() throws -> String {
        String(decoding: try FixtureBytes.data("message-html-remote-images.html"), as: UTF8.self)
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
                addresses: recorded.addresses,
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
            accountId: accountId,
            mailboxId: mailboxId,
            threadRootId: recorded.threadRootId
        )
    }

    /// A second message in the same mailbox, from another recorded envelope, for the
    /// selection to move to.
    private static func seedOtherMessage(_ mirror: Mirror) async throws -> Int64 {
        let object = try JSONSerialization.jsonObject(with: try FixtureBytes.data("messages-inbox-page1.json"))
        let envelope = try #require((object as? [[String: Any]])?.first { ($0["databaseId"] as? Int) == 58 })
        let ids = try await mirror.store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: 58,
                mailboxId: mirror.mailboxId,
                accountId: mirror.accountId,
                sentAt: 1_789_920_000,
                syncedAt: 1_789_920_999,
                messageId: envelope["messageId"] as? String,
                threadRootId: envelope["threadRootId"] as? String,
                subject: "Subject redacted",
                fromEmail: "user@example.com",
                fromLabel: "Name redacted",
                rawJSON: String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            )
        ])
        return try #require(ids.first)
    }

    private static func storeBody(
        _ mirror: Mirror,
        messageId: Int64? = nil,
        html: String? = nil,
        plain: String? = nil
    ) async throws {
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
            for: messageId ?? mirror.messageId
        )
    }

    /// Spins the main actor until `condition` holds.
    ///
    /// Yielding is what lets a pending observation delivery run, but the database writes
    /// those deliveries report happen off the main actor, so under load the yields can all
    /// elapse before the write lands. The bound is therefore a clock, not a yield count.
    private static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        limit: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
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
        // Read from `messageAddress` through `MailStore.addresses(messageId:)`, which is the
        // table that holds them — this used to decode the envelope back out of
        // `message.rawJSON` because the table had no reader.
        #expect(header.to.count == 1)
        #expect(header.to.first?.email == "user@example.com")
        #expect(header.cc.isEmpty)
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
        #expect(context.remoteMessageId == (try Self.recordedEnvelope().remoteId))
    }

    @Test("the body write is what the observation the view is already on reports")
    func theBodyWriteTicksTheObservation() async throws {
        let mirror = try await Self.seed()
        var iterator = mirror.store.observeBody(messageId: mirror.messageId).makeAsyncIterator()

        let before = try await iterator.next()
        #expect(before ?? nil == nil, "no body row yet, which is what a message the backfill has not reached is")

        try await Self.storeBody(mirror, plain: "Hello.")

        // `upsert(body:for:)` writes the body row, its attachments and `message.bodyState`
        // in one transaction, so this value arrives exactly when the body lands. It is the
        // signal the message view rides.
        let after = try await iterator.next()
        #expect(after??.body.plainBody == "Hello.")
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
        guard case .plain(let content) = mirror.model.presentation else {
            Issue.record("expected the native renderer, got \(mirror.model.presentation)")
            return
        }
        #expect(content.text == "Hello, and https://example.com/x")
        #expect(content.signature == nil)
        // Found when the body was read, so the view's body has nothing left to detect.
        #expect(content.linkedText.runs.compactMap { $0.link?.absoluteString } == ["https://example.com/x"])
        #expect(!mirror.model.hasBlockedRemoteContent)
    }

    // MARK: - What may write the body area

    @Test("a rewrite still running when the selection moves never lands under the next message")
    func aStaleRenderIsDiscarded() async throws {
        let mirror = try await Self.seed()
        let next = try await Self.seedOtherMessage(mirror)
        // About 2 MB: long enough that the rewrite is still running when the selection
        // moves, and that the next message's plain body is drawn before it finishes.
        try await Self.storeBody(mirror, html: String(repeating: try Self.recordedHTML(), count: 64))
        try await Self.storeBody(mirror, messageId: next, plain: "The next message.")

        mirror.model.present(messageId: mirror.messageId)
        // The observation assigns the attachments and starts the rewrite in one main-actor
        // turn, so once they are here the rewrite is in flight.
        #expect(await Self.waitUntil { !mirror.model.attachments.isEmpty })
        mirror.model.present(messageId: next)

        // Written in the turn the rewrite returns, before its result could be assigned.
        #expect(await Self.waitUntil { mirror.model.lastRewriteMilliseconds > 0 })
        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })
        #expect(mirror.model.header?.messageId == next)
        #expect(mirror.model.presentation == .plain(PlainTextBody(text: "The next message.", signature: nil)))
        #expect(!mirror.model.hasBlockedRemoteContent)
    }

    @Test("a body delivered again unchanged is not drawn again, but its attachments still update")
    func anUnchangedBodyIsNotRedrawn() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, html: try Self.recordedHTML())
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.presentation != .waiting })

        // A presentation no render produces, so a redraw would show.
        mirror.model.contentRuleListFailed("no rule list")

        // Each stored inline image rewrites the attachment row and re-delivers the body
        // with the same HTML. Waiting for the first delivery before writing the second means
        // a redraw started by the first would have landed before the second is seen: the
        // observation renders one value before it reads the next.
        for byte: UInt8 in [1, 2] {
            try await mirror.store.storeInlineAttachment(
                messageId: mirror.messageId,
                attachmentId: "2",
                data: Data([byte]),
                fetchedAt: 1_789_921_100
            )
            #expect(await Self.waitUntil { mirror.model.attachments.first?.data == Data([byte]) })
        }
        #expect(mirror.model.presentation == .blocked("no rule list"))

        // A different decision is a different input, and draws again.
        mirror.model.showImages()
        #expect(
            await Self.waitUntil {
                guard case .html(_, let context) = mirror.model.presentation else { return false }
                return context.showsRemoteImages
            }
        )
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

    // MARK: - Thread mode (WS-30, ADR-0085)

    /// A second message in the same conversation, as the sync engine would write it; in the
    /// selected message's mailbox unless `mailboxId` says otherwise.
    private static func addSibling(
        _ mirror: Mirror,
        remoteId: Int64 = 9_001,
        mailboxId: Int64? = nil,
        flags: NCMailStore.MessageFlags = NCMailStore.MessageFlags()
    ) async throws -> Int64 {
        let stored = try await mirror.store.message(id: mirror.messageId)
        let record = try #require(stored)
        let ids = try await mirror.store.upsert(envelopes: [
            EnvelopeWrite(
                remoteId: remoteId,
                mailboxId: mailboxId ?? mirror.mailboxId,
                accountId: record.accountId,
                sentAt: 1_789_930_000,
                syncedAt: 1_789_930_001,
                messageId: "<sibling-\(remoteId)@example.com>",
                threadRootId: mirror.threadRootId,
                subject: "Re: Subject redacted",
                flags: flags,
                fromEmail: "rory@example.com",
                fromLabel: "Rory",
                addresses: [EnvelopeAddress(kind: .to, email: "user@example.com")]
            )
        ])
        return try #require(ids.first)
    }

    @Test("the conversation lists every message and expands only the selected one")
    func threadExpandsTheSelection() async throws {
        let mirror = try await Self.seed()
        let sibling = try await Self.addSibling(mirror)
        mirror.model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { mirror.model.thread.count == 2 })
        #expect(mirror.model.expandedId == mirror.messageId)
        let split = ThreadSplit(thread: mirror.model.thread, expandedId: mirror.model.expandedId)
        #expect(split.before.isEmpty)
        #expect(split.after.map(\.id) == [sibling])
    }

    @Test("expanding a sibling draws it in place and collapses the other; the selection stays")
    func expandingASiblingSwapsTheExpandedMessage() async throws {
        let mirror = try await Self.seed()
        let sibling = try await Self.addSibling(mirror)
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.thread.count == 2 })

        mirror.model.toggle(sibling)
        #expect(mirror.model.expandedId == sibling)
        #expect(mirror.model.selectedId == mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.header?.messageId == sibling })
        #expect(mirror.model.header?.sender?.email == "rory@example.com")

        // Collapsing the expanded one leaves the conversation collapsed.
        mirror.model.toggle(sibling)
        #expect(mirror.model.expandedId == nil)
        #expect(mirror.model.header == nil)
    }

    @Test("a conversation of one cannot be collapsed")
    func singleMessageStaysExpanded() async throws {
        let mirror = try await Self.seed()
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.header != nil })
        mirror.model.toggle(mirror.messageId)
        #expect(mirror.model.expandedId == mirror.messageId)
    }

    @Test("an expanded sibling is marked read through the reader's delay, not the selection")
    func expandingMarksOpened() async throws {
        let mirror = try await Self.seed()
        let sibling = try await Self.addSibling(mirror)
        let opened = OpenedRecorder()
        let model = MessageViewModel(
            services: MessageViewServices(
                store: mirror.store,
                client: mirror.model.services.client,
                server: mirror.model.services.server,
                messageOpened: { id in opened.ids.append(id) }
            )
        )
        model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { model.thread.count == 2 })
        model.toggle(sibling)
        #expect(await Self.waitUntil { opened.ids == [sibling] })
    }

    @MainActor
    final class OpenedRecorder {
        var ids: [Int64] = []
    }

    // MARK: - PGP, read receipts, server results

    @Test("a PGP message shows the notice and none of its body")
    func pgpShowsTheNoticeOnly() async throws {
        let mirror = try await Self.seed()
        var flags = NCMailStore.MessageFlags()
        flags.isEncrypted = true
        let pgp = try await Self.addSibling(mirror, flags: flags)
        try await mirror.store.upsert(
            body: MessageBodyWrite(
                fetchedAt: 1, plainBody: "-----BEGIN PGP MESSAGE-----\nhQEMA\n-----END PGP MESSAGE-----"),
            for: pgp
        )
        mirror.model.present(messageId: pgp)
        #expect(await Self.waitUntil { mirror.model.presentation == .encrypted })
        #expect(mirror.model.security.isPGP)
        #expect(mirror.model.printable?.body == .headerOnly(note: MessagePGPNotice.text))
    }

    @Test("Notify the sender queues sendMDN, and $mdnsent lands locally at once")
    func readReceiptIsQueued() async throws {
        let mirror = try await Self.seed()
        try await mirror.store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, plainBody: "Hi", dispositionNotificationTo: "user@example.com"),
            for: mirror.messageId
        )
        let model = MessageViewModel(
            services: MessageViewServices(
                store: mirror.store,
                client: mirror.model.services.client,
                server: mirror.model.services.server,
                queue: MutationQueue(store: mirror.store)
            )
        )
        model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { model.security.readReceipt == .requested })

        await model.sendReadReceipt()
        #expect(model.actionError == nil)
        #expect(model.security.readReceipt == .sent)
        #expect(await Self.waitUntil { model.header?.isMdnSent == true })
        let accountId = try #require(model.header?.accountId)
        let queued = try await mirror.store.pendingOperations(accountId: accountId)
        #expect(queued.map(\.kind).contains("sendMDN"))
    }

    @Test("smart replies are read from their serverResult row, pending until it exists")
    func smartRepliesComeFromTheRow() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, plain: "Lunch tomorrow?")
        let login = try await mirror.store.ensureLogin(ServerIdentity(serverURL: Self.server, loginName: "lorelai"))
        let loginId = try #require(login.id)
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.smartReplies == .pending })

        // What `ServerResultFetcher` writes when the route answers.
        try await mirror.store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId,
                kind: ServerResultKind.smartReply.rawValue,
                key: ServerResultKind.messageKey(mirror.messageId),
                payloadJSON: #"{"status":"ready","data":["Sounds good","Can't make it"]}"#,
                fetchedAt: 1
            )
        )
        #expect(await Self.waitUntil { mirror.model.smartReplies == .ready(["Sounds good", "Can't make it"]) })
    }

    @Test("an empty smart-reply row (the 204 of a server with no LLM) shows nothing")
    func emptySmartRepliesShowNothing() async throws {
        let mirror = try await Self.seed()
        let login = try await mirror.store.ensureLogin(ServerIdentity(serverURL: Self.server, loginName: "lorelai"))
        let loginId = try #require(login.id)
        try await mirror.store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId,
                kind: ServerResultKind.smartReply.rawValue,
                key: ServerResultKind.messageKey(mirror.messageId),
                payloadJSON: #"{"status":"empty"}"#,
                fetchedAt: 1
            )
        )
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.smartReplies == .empty })
        #expect(mirror.model.smartReplies.value == nil)
    }

    @Test("opening a message whose empty smart-reply row predates LLM being turned on asks again")
    func staleEmptySmartRepliesAreAskedAgainOnOpen() async throws {
        let mirror = try await Self.seed()
        let identity = ServerIdentity(serverURL: Self.server, loginName: "lorelai")
        let loginId = try #require(try await mirror.store.ensureLogin(identity).id)
        // An hour old: inside smart reply's one-day expiry, past the empty-row cap.
        try await mirror.store.upsert(
            serverResult: ServerResultRecord(
                loginId: loginId,
                kind: ServerResultKind.smartReply.rawValue,
                key: ServerResultKind.messageKey(mirror.messageId),
                payloadJSON: #"{"status":"empty"}"#,
                fetchedAt: Int64(Date().timeIntervalSince1970) - 3_600
            )
        )
        // The server's answer once processing is on, as recorded live: a bare array.
        let client = MailClient(
            server: try #require(URL(string: Self.server)),
            credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
            transport: ReplayTransport.replaying(try FixtureBytes.data("message-smartreply-populated.json"))
        )
        let model = MessageViewModel(
            services: MessageViewServices(
                store: mirror.store,
                client: client,
                server: mirror.model.services.server,
                serverResults: ServerResultFetcher(store: mirror.store, client: client, identity: identity)
            )
        )
        model.present(messageId: mirror.messageId)
        #expect(
            await Self.waitUntil {
                model.smartReplies == .ready(["Perfect, see you Sat!", "Can we meet at ____ first?"])
            })
    }

    @Test("whole-thread print reads collapsed messages from the mirror, missing bodies as a line")
    func printableThreadIncludesCollapsedMessages() async throws {
        let mirror = try await Self.seed()
        try await Self.storeBody(mirror, plain: "First body")
        _ = try await Self.addSibling(mirror)
        mirror.model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { mirror.model.thread.count == 2 && mirror.model.printable != nil })

        let printout = await mirror.model.printableThread()
        #expect(printout.count == 2)
        #expect(printout.first?.body == .plain(text: "First body", signature: nil))
        #expect(printout.last?.body == .headerOnly(note: "This message has not been downloaded yet."))
        #expect(printout.last?.header.sender?.email == "rory@example.com")
    }

    // MARK: - Thread summary and Reply with meeting over the recorded LLM answers

    /// A model whose fetcher answers every request with `fixture`, recorded live.
    private static func replaying(_ fixture: String, over mirror: Mirror) async throws -> MessageViewModel {
        let identity = ServerIdentity(serverURL: server, loginName: "lorelai")
        _ = try await mirror.store.ensureLogin(identity)
        let client = MailClient(
            server: try #require(URL(string: server)),
            credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
            transport: ReplayTransport.replaying(try FixtureBytes.data(fixture))
        )
        return MessageViewModel(
            services: MessageViewServices(
                store: mirror.store,
                client: client,
                server: mirror.model.services.server,
                serverResults: ServerResultFetcher(store: mirror.store, client: client, identity: identity)
            )
        )
    }

    private static func addMailbox(
        _ mirror: Mirror, remoteId: Int64, name: String, role: String
    ) async throws -> Int64 {
        let record = try #require(try await mirror.store.message(id: mirror.messageId))
        let write = MailboxWrite(
            accountId: record.accountId, remoteId: remoteId, name: name, displayName: name, specialRole: role)
        let mailboxes = try await mirror.store.upsert(mailboxes: [write], accountId: record.accountId)
        return try #require(mailboxes.first).id
    }

    @Test("two in the Inbox and the reply in Sent are a conversation of three: the summary is asked and shown")
    func threadSummaryCountsTheConversationAcrossMailboxes() async throws {
        let mirror = try await Self.seed()
        _ = try await Self.addSibling(mirror)
        let sent = try await Self.addMailbox(mirror, remoteId: 6, name: "Sent", role: "sent")
        _ = try await Self.addSibling(mirror, remoteId: 9_002, mailboxId: sent)
        let model = try await Self.replaying("thread-summary-populated.json", over: mirror)
        model.present(messageId: mirror.messageId)

        #expect(await Self.waitUntil { model.thread.count == 2 && model.conversationSize == 3 })
        #expect(await Self.waitUntil { model.threadSummary.value?.hasPrefix("Two friends arrange") == true })
    }

    @Test("a copy in Trash does not make a conversation of three: no summary is asked")
    func threadSummaryIgnoresTrash() async throws {
        let mirror = try await Self.seed()
        _ = try await Self.addSibling(mirror)
        let trash = try await Self.addMailbox(mirror, remoteId: 7, name: "Trash", role: "trash")
        _ = try await Self.addSibling(mirror, remoteId: 9_003, mailboxId: trash)
        let model = try await Self.replaying("thread-summary-populated.json", over: mirror)
        model.present(messageId: mirror.messageId)

        #expect(
            await Self.waitUntil {
                model.thread.count == 2 && model.conversationSize == 2 && model.resolvedLoginId != nil
            })
        #expect(model.threadSummary == .idle)
    }

    @Test("Reply with meeting: the event data lands and fills the title and description")
    func meetingFormTakesTheEventData() async throws {
        let mirror = try await Self.seed()
        let model = try await Self.replaying("thread-eventdata-populated.json", over: mirror)
        model.present(messageId: mirror.messageId)
        #expect(await Self.waitUntil { model.header != nil && model.resolvedLoginId != nil })

        let form = MeetingForm()
        let calendar = MessageCalendarModel(services: model.services)
        let preparing = Task { await form.prepare(message: model, calendar: calendar) }
        defer { preparing.cancel() }

        #expect(await Self.waitUntil { form.generation?.value != nil })
        #expect(form.draft.title == "Saturday Afternoon Bookshop Visit")
        #expect(form.draft.description.hasPrefix("* Meet at the bookshop"))
        #expect(form.draft.description.hasSuffix("This description was generated by AI."))
    }

    @Test("Reply with meeting: a field written back unchanged still fills; one the reader changed is kept")
    func meetingFormFillsOnlyUnchangedFields() throws {
        let suggestion = try #require(
            MeetingSuggestion(.object(["summary": .string("AI title"), "description": .string("AI text")])))

        // What a focused SwiftUI field does as the sheet appears: its text, back, unchanged.
        let untouched = MeetingForm()
        untouched.draft.title = untouched.draft.title
        untouched.apply(suggestion)
        #expect(untouched.draft.title == "AI title")

        let edited = MeetingForm()
        edited.draft.title = "Lunch"
        edited.apply(suggestion)
        #expect(edited.draft.title == "Lunch")
        #expect(edited.draft.description.hasPrefix("AI text"))
    }
}
