// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-30's §5 rows against the live server, through the view model and the three engine
/// doors it is given — exactly the objects `AppSession.messageServices` hands the pane.
///
/// The suite seeds its own mail, to the account's own address only (the standing send rule):
/// one message asking for a read receipt, one inline-PGP message, and a reply to the first so
/// the conversation has two messages. Numbers go to stderr as `[measured]`.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_MIRROR=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin xcodebuild test -project NextcloudMail.xcodeproj \
///   -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/MessageViewLiveTests
/// ```
@MainActor
@Suite("Message view against a live server", .serialized)
struct MessageViewLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }

    enum LiveError: Error { case missingEnvironment, notDelivered(String) }

    struct Live {
        let store: MailStore
        let client: MailClient
        let identity: ServerIdentity
        let account: AccountRecord
        let inbox: MailboxRecord
        let drainer: OperationDrainer

        func services() -> MessageViewServices {
            MessageViewServices(
                store: store,
                client: client,
                server: URL(string: identity.serverURL) ?? URL(fileURLWithPath: "/"),
                serverResults: ServerResultFetcher(store: store, client: client, identity: identity),
                queue: MutationQueue(store: store, drainer: drainer),
                exporter: MessageExporter(store: store, client: client)
            )
        }

        /// Server envelopes in the inbox whose subject carries `token`, after a cache sync.
        func envelopes(_ token: String) async throws -> [RawBacked<Envelope>] {
            _ = try? await client.post(.sync(mailboxId: Int(inbox.remoteId)))
            return try await client.get(.messages(mailboxId: Int(inbox.remoteId), filter: "subject:\(token)"))
                .filter { $0.value.subject?.contains(token) == true }
        }

        /// Envelopes and bodies for `token` into the mirror, the way the backfill writes them.
        func mirror(_ token: String, also extra: [RawBacked<Envelope>] = []) async throws -> [Int64] {
            var page = try await envelopes(token)
            for envelope in extra where !page.contains(where: { $0.value.id == envelope.value.id }) {
                page.append(envelope)
            }
            let ids = try await store.upsert(
                envelopes: try page.map {
                    try MirrorMapping.envelopeWrite($0, accountId: account.id, mailboxId: inbox.id, syncedAt: 1)
                })
            for (raw, id) in zip(page, ids) {
                let body = try await client.get(.messageBody(id: raw.value.id))
                var html: String?
                if body.value.hasHtmlBody {
                    html = String(decoding: try await client.bytes(.messageHTML(id: raw.value.id)).0, as: UTF8.self)
                }
                try await store.upsert(body: try MirrorMapping.bodyWrite(body, html: html, fetchedAt: 1), for: id)
            }
            return ids
        }

        func send(subject: String, body: String, requestMdn: Bool = false, inReplyTo: String? = nil) async throws {
            let request = ComposeMessageRequest(
                accountId: Int(account.remoteId),
                subject: subject,
                bodyPlain: body,
                isHtml: false,
                to: [RecipientRequest(email: account.emailAddress)],
                inReplyToMessageId: inReplyTo,
                requestMdn: requestMdn
            )
            let queued = try await client.post(.enqueueMessage, body: request)
            do {
                _ = try await client.post(.sendOutboxMessage(id: queued.data.value.id))
            } catch {
                // Seen live 2026-10-04: the send answers 409/500 while the message is
                // delivered (the IMAP copy to Sent is the step that fails). Arrival in the
                // inbox is what the seed waits for, so the status is only reported.
                MessageViewLiveTests.report("outbox send answered \(error); waiting for delivery anyway")
            }
        }
    }

    /// One seeding per process: the sends take the better part of a minute to arrive.
    struct Seed {
        let live: Live
        let token: String
        let mdnId: Int64
        let replyId: Int64
        let pgpId: Int64
    }

    private static var seeded: Result<Seed, any Error>?

    /// Seeded once per process, failure included: a failed seed is not retried by every test,
    /// which would only send more mail.
    static func seed() async throws -> Seed {
        if let seeded { return try seeded.get() }
        do {
            let seed = try await makeSeed()
            seeded = .success(seed)
            return seed
        } catch {
            seeded = .failure(error)
            throw error
        }
    }

    private static func makeSeed() async throws -> Seed {
        let live = try await connect()
        let client = live.client
        let store = live.store
        let inbox = live.inbox

        // A token whose probes were already delivered is reused rather than sent again: every
        // run otherwise adds three self-sends, and the SMTP relay started refusing them.
        let reused = environment["NCMAIL_LIVE_WS30_TOKEN"]
        let token = reused ?? "ws30-\(UUID().uuidString.prefix(8).lowercased())"
        if reused == nil {
            let started = ContinuousClock.now
            try await live.send(
                subject: "\(token) read receipt",
                body: "WS-30 live probe: the sender of this message asks to be notified.",
                requestMdn: true)
            try await live.send(
                subject: "\(token) inline pgp",
                body:
                    "-----BEGIN PGP MESSAGE-----\n\nhQEMA0000000000000AQf/WS30probe\n=abcd\n-----END PGP MESSAGE-----\n"
            )
            let first = try await waitFor(live, token) { found in
                found.contains { $0.value.subject?.hasSuffix("read receipt") == true }
                    && found.contains { $0.value.subject?.hasSuffix("inline pgp") == true }
            }
            let original = try #require(first.first { $0.value.subject == "\(token) read receipt" })
            try await live.send(
                subject: "Re: \(token) read receipt",
                body: "WS-30 live probe: a reply, so the conversation has two messages.",
                inReplyTo: original.value.messageId)
            _ = try await waitFor(live, token) { found in found.contains { $0.value.subject?.hasPrefix("Re:") == true }
            }
            report("seeding 3 self-sends to arrival: \(ContinuousClock.now - started)")
        }

        // The list shows one message per thread, so the conversation comes from the thread
        // route, inbox copies only.
        let listed = try await live.envelopes(token)
        let latest = try #require(listed.first { $0.value.subject?.contains("read receipt") == true })
        let thread = try await client.get(
            Endpoint<[RawBacked<Envelope>]>(
                name: "thread", method: .get, encodedPath: "messages/\(latest.value.id)/thread", isRetryable: true))
        let ids = try await live.mirror(
            token, also: thread.filter { $0.value.mailboxId == Int(inbox.remoteId) })
        var byKind: [String: Int64] = [:]
        for id in ids {
            guard let subject = try await store.message(id: id)?.subject else { continue }
            if subject.hasPrefix("Re:") {
                byKind["reply"] = id
            } else if subject.hasSuffix("inline pgp") {
                byKind["pgp"] = id
            } else {
                byKind["mdn"] = id
            }
        }
        return Seed(
            live: live, token: token,
            mdnId: try #require(byKind["mdn"]), replyId: try #require(byKind["reply"]),
            pgpId: try #require(byKind["pgp"]))
    }

    /// The account's mirror with its mailboxes and nothing else: no mail sent.
    static func connect() async throws -> Live {
        guard
            let raw = environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "ws30-live-test")
        let identity = ServerIdentity(serverURL: server.absoluteString, loginName: user)
        _ = try await store.ensureLogin(identity)
        let accounts = try await MirrorCoordinator.discoverAccounts(store: store, client: client, identity: identity)
        let account = try #require(accounts.first)
        let list = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
        try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
            accountId: account.id)
        let inbox = try #require(
            try await store.mailboxes(accountId: account.id).first { $0.specialRole?.lowercased() == "inbox" })
        return Live(
            store: store, client: client, identity: identity, account: account, inbox: inbox,
            drainer: OperationDrainer(store: store, client: client, accountId: account.id))
    }

    /// A real conversation of three or more already on the server — two in the Inbox and
    /// the reply in Sent is the usual shape — mirrored into the mailboxes it lives in, with
    /// the bodies. Returns the local id of one of its Inbox messages, the one to open.
    static func mirrorRealConversation(_ live: Live) async throws -> Int64 {
        let mailboxes = try await live.store.mailboxes(accountId: live.account.id)
        let local = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.remoteId, $0) })
        let listed = try await live.client.get(.messages(mailboxId: Int(live.inbox.remoteId)))
        for candidate in listed {
            let thread = try await live.client.get(
                Endpoint<[RawBacked<Envelope>]>(
                    name: "thread", method: .get, encodedPath: "messages/\(candidate.value.id)/thread",
                    isRetryable: true))
            let counted = thread.filter {
                let role = local[Int64($0.value.mailboxId)]?.specialRole
                return role != "trash" && role != "junk"
            }
            guard counted.count >= 3, thread.contains(where: { $0.value.mailboxId == Int(live.inbox.remoteId) })
            else { continue }
            var opened: Int64?
            for raw in counted {
                let mailbox = try #require(local[Int64(raw.value.mailboxId)])
                let ids = try await live.store.upsert(envelopes: [
                    try MirrorMapping.envelopeWrite(
                        raw, accountId: live.account.id, mailboxId: mailbox.id, syncedAt: 1)
                ])
                let id = try #require(ids.first)
                let body = try await live.client.get(.messageBody(id: raw.value.id))
                try await live.store.upsert(body: try MirrorMapping.bodyWrite(body, html: nil, fetchedAt: 1), for: id)
                if mailbox.id == live.inbox.id { opened = id }
            }
            report("conversation \"\(candidate.value.subject ?? "")\": \(counted.count) messages")
            return try #require(opened)
        }
        throw LiveError.notDelivered("no conversation of three in the inbox")
    }

    private static func waitFor(
        _ live: Live,
        _ token: String,
        until done: ([RawBacked<Envelope>]) -> Bool
    ) async throws -> [RawBacked<Envelope>] {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            let found = try await live.envelopes(token)
            if done(found) { return found }
            try await Task.sleep(for: .seconds(3))
        }
        throw LiveError.notDelivered(token)
    }

    private static func waitUntil(
        _ limit: Duration = .seconds(60), _ condition: @MainActor () async -> Bool
    ) async
        -> Duration?
    {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < limit {
            if await condition() { return ContinuousClock.now - started }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition() ? ContinuousClock.now - started : nil
    }

    nonisolated private static func report(_ text: String) {
        FileHandle.standardError.write(Data(("  [measured] " + text + "\n").utf8))
    }

    // MARK: - §5.1 thread container

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func threadShowsBothMessagesAndExpandsInPlace() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        let elapsed = await Self.waitUntil { model.thread.count >= 2 }
        #expect(elapsed != nil)
        #expect(model.expandedId == seed.mdnId)
        model.toggle(seed.replyId)
        #expect(await Self.waitUntil { model.header?.messageId == seed.replyId } != nil)
        #expect(model.selectedId == seed.mdnId)
        Self.report("thread of \(model.thread.count) observed in \(elapsed.map(String.init(describing:)) ?? "never")")
    }

    // MARK: - §5.7 read receipt, PGP

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func readReceiptReachesTheServer() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.security.readReceipt == .requested } != nil)

        await model.sendReadReceipt()
        #expect(model.actionError == nil)
        await seed.live.drainer.drain()
        #expect(try await seed.live.store.pendingOperations(accountId: seed.live.account.id).isEmpty)
        let server = try await seed.live.envelopes(seed.token).first {
            $0.value.subject?.hasSuffix("read receipt") == true
        }
        #expect(server?.value.flags.mdnSent == true)
    }

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func inlinePGPShowsTheNoticeOnly() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.pgpId)
        #expect(await Self.waitUntil { model.presentation == .encrypted } != nil)
        #expect(model.printable?.body == .headerOnly(note: MessagePGPNotice.text))
    }

    // MARK: - §5.5, §5.8, §5.4 server results

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func serverResultsLandAsRows() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.header != nil } != nil)

        // LLM processing is on (2026-10-04): the route's bare array is a `ready` row. With it
        // off the row would be `empty` — the 204 — and re-asked after `emptyRetryAfter`.
        let replies = await Self.waitUntil { model.smartReplies != .pending && model.smartReplies != .idle }
        #expect(replies != nil)
        #expect(model.smartReplies.value?.isEmpty == false)
        Self.report(
            "smart replies row: \(model.smartReplies) after \(replies.map(String.init(describing:)) ?? "never")")

        model.requestSource()
        let source = await Self.waitUntil { model.source.value != nil }
        #expect(model.source.value?.contains(seed.token) == true)
        Self.report("message source row in \(source.map(String.init(describing:)) ?? "never")")

        // No translation provider: OCS 412, a `failed` row, "could not be translated".
        model.requestTranslation(to: "de", from: nil)
        let translation = await Self.waitUntil { model.translation == .failed || model.translation == .empty }
        #expect(translation != nil)
        Self.report("translation row: \(model.translation) in \(translation.map(String.init(describing:)) ?? "never")")
    }

    // MARK: - Thread summary and Reply with meeting on a real conversation

    /// A real conversation of three (two in the Inbox, the reply in Sent): the summary card
    /// reaches `.ready` with the server's text, and the Reply with meeting form takes the
    /// event data over its title and description.
    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer), .timeLimit(.minutes(5)))
    func realConversationGetsItsSummaryAndMeetingDetails() async throws {
        let live = try await Self.connect()
        let opened = try await Self.mirrorRealConversation(live)
        let model = MessageViewModel(services: live.services())
        model.present(messageId: opened)

        let summarised = await Self.waitUntil(.seconds(180)) {
            model.threadSummary != .pending && model.threadSummary != .idle
        }
        Self.report(
            "thread of \(model.thread.count) shown, \(model.conversationSize) in the conversation: "
                + "\(model.threadSummary) after \(summarised.map(String.init(describing:)) ?? "never")")
        #expect(model.conversationSize >= 3)
        #expect(model.threadSummary.value?.isEmpty == false)

        let form = MeetingForm()
        let calendar = MessageCalendarModel(services: model.services)
        let preparing = Task { await form.prepare(message: model, calendar: calendar) }
        defer { preparing.cancel() }
        let generated = await Self.waitUntil(.seconds(180)) {
            form.generation != nil && form.generation != .pending
        }
        let state = form.generation
        Self.report(
            "event data: \(String(describing: state)) after "
                + "\(generated.map(String.init(describing:)) ?? "never"); title \"\(form.draft.title)\"")
        let suggestion = try #require(state?.value)
        #expect(suggestion.summary.map { form.draft.title == $0 } ?? true)
        #expect(form.draft.description.hasSuffix("This description was generated by AI."))
    }

    // MARK: - §5.4 download, save to Files, trust domain; §5.10 zip

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func downloadsWriteTheFileTheReaderChose() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.header != nil } != nil)

        let folder = FileManager.default.temporaryDirectory.appending(path: seed.token, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let eml = folder.appending(path: "message.eml")
        await model.export(.eml, to: eml)
        #expect(model.actionError == nil)
        let text = try String(contentsOf: eml, encoding: .utf8)
        #expect(text.contains(seed.token))
        Self.report(".eml export \(text.utf8.count) bytes")

        // The recorder's attachment self-send is on the server; zip it.
        let attachments = try await seed.live.mirror("Fixture attachment message")
        let withAttachments = try #require(attachments.first)
        let zipModel = MessageViewModel(services: seed.live.services())
        zipModel.present(messageId: withAttachments)
        #expect(await Self.waitUntil { !zipModel.attachments.isEmpty } != nil)
        let zip = folder.appending(path: "attachments.zip")
        await zipModel.export(.attachmentsZip, to: zip)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.prefix(2) == Data("PK".utf8))
        Self.report("zip export \(bytes.count) bytes")

        // Quick Look of an attachment the mirror has no bytes for goes through the exporter.
        let first = try #require(zipModel.attachments.first { !$0.isInline })
        await zipModel.preview(first)
        let preview = try #require(zipModel.previewURL)
        #expect(try Data(contentsOf: preview).count > 0)
    }

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func saveToFilesAndTrustDomainDrain() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.header != nil } != nil)

        await model.saveToFiles(attachmentIds: [nil], targetPath: "/")
        #expect(model.actionError == nil)
        #expect(model.actionNotice == "Message saved to Files")
        await model.trustSenderDomain()
        #expect(model.actionError == nil)
        await seed.live.drainer.drain()
        #expect(try await seed.live.store.pendingOperations(accountId: seed.live.account.id).isEmpty)

        let domain = try #require(model.senderDomain)
        let trusted = try await seed.live.client.get(.trustedSenders)
        #expect(String(describing: trusted).contains(domain))

        // Leave the server as it was.
        try await MutationQueue(store: seed.live.store).perform(
            .trustDomain(domain: domain, trusted: false), accountId: seed.live.account.id)
        await seed.live.drainer.drain()
    }

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func directLinkNamesTheMessageID() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.header != nil } != nil)
        let header = try #require(model.header?.messageIdHeader)
        let url = try #require(MessageDirectLink.url(messageIdHeader: header))
        #expect(url.absoluteString.hasPrefix("ncmail://open/%3C"))
        #expect(url.absoluteString.removingPercentEncoding == "ncmail://open/\(header)")
    }

    @Test(.enabled(if: MessageViewLiveTests.hasLiveServer))
    func wholeThreadPrintReadsBothMessages() async throws {
        let seed = try await Self.seed()
        let model = MessageViewModel(services: seed.live.services())
        model.present(messageId: seed.mdnId)
        #expect(await Self.waitUntil { model.thread.count >= 2 && model.printable != nil } != nil)
        let started = ContinuousClock.now
        let printout = await model.printableThread()
        #expect(printout.count == model.thread.count)
        let document = MessagePrintDocument.html(forThread: printout)
        #expect(document.contains("WS-30 live probe: a reply"))
        Self.report("whole-thread printable built in \(ContinuousClock.now - started), \(document.utf8.count) bytes")
    }
}
