// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// WS-27's acceptance against a live server, through the real `ComposerModel` and the real
/// engines `AccountEngine` starts: compose and send, reply-all prefill, forward with
/// attachments, send later into the Outbox, undo, and an offline send that drains on
/// reconnect. Every message goes to the account's own address only.
///
/// Each test owns a fresh engine and stops it even when it fails, so no two engines sync
/// the same mailboxes. A test whose message the server's SMTP relay refuses (outbox status 10)
/// is cancelled at the delivery step with that reason, after every queue and outbox assertion.
///
/// Off by default (sockets; definition-of-done.md). `localhost`, not `nextcloud.local`: the
/// app-hosted runner cannot resolve mDNS names.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_COMPOSER=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/ComposerLiveTests test
/// ```
@Suite("Composer against a live server", .serialized)
@MainActor
struct ComposerLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_COMPOSER"]

    enum LiveError: Error { case missingEnvironment, timedOut(String) }

    final class Live {
        let session: ComposerServices
        let account: AccountRecord
        let client: MailClient
        let folder: URL
        let inboxId: Int64
        let sentId: Int64
        var timings: [String] = []
        /// How many `serverMessages` probes met a sync lock (409) and asked again.
        var lockedProbes = 0

        init(
            session: ComposerServices, account: AccountRecord, client: MailClient, folder: URL, inboxId: Int64,
            sentId: Int64
        ) {
            self.session = session
            self.account = account
            self.client = client
            self.folder = folder
            self.inboxId = inboxId
            self.sentId = sentId
        }

        var me: ComposerAddress { ComposerAddress(email: account.emailAddress, label: account.name) }

        func model(_ request: ComposeRequest) async -> ComposerModel {
            let model = ComposerModel(request: request, session: session)
            await model.load(restoringDraftId: nil)
            return model
        }

        func remoteMailboxId(_ id: Int64) async throws -> Int {
            Int(try #require(try await session.store.mailbox(id: id)).remoteId)
        }

        /// Server ids in a mailbox whose subject contains `token`, after a server cache sync.
        ///
        /// `GET messages` answers 409 (`MailboxLockedException`) while any sync of the mailbox
        /// holds a lock — this probe's own, the engine's after a send, another client's. That
        /// is "ask again", not an answer, so the probe asks again until it gets one; an empty
        /// list is therefore a real answer, which the negative checks below rely on.
        func serverMessages(in mailbox: Int64, token: String) async throws -> [RawBacked<Envelope>] {
            let remote = try await remoteMailboxId(mailbox)
            let start = Date()
            while true {
                do {
                    _ = try? await client.post(.sync(mailboxId: remote))
                    return try await client.get(.messages(mailboxId: remote, filter: "subject:\(token)"))
                        .filter { $0.value.subject?.contains(token) == true }
                } catch MailError.server(status: 409, _) where Date().timeIntervalSince(start) < 60 {
                    lockedProbes += 1
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }

        /// The mirrored message in `mailbox` with `token` in its subject.
        func mirrored(in mailbox: Int64, token: String) async throws -> MessageRow? {
            session.engine.refresh(mailboxId: mailbox, accountId: account.id)
            return try await session.store.messages(mailboxId: mailbox, view: .flat, range: 0..<300)
                .first { $0.subject?.contains(token) == true }
        }

        @discardableResult
        func waitUntil(
            _ what: String, timeout: TimeInterval = 90, _ condition: () async throws -> Bool
        ) async throws
            -> Double
        {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if try await condition() {
                    let took = Date().timeIntervalSince(start)
                    timings.append("\(what) \(String(format: "%.1f", took)) s")
                    return took
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw LiveError.timedOut(what)
        }

        func row(_ draftId: Int64?) async throws -> DraftRecord? {
            guard let draftId else { return nil }
            return try await session.store.draft(id: draftId)
        }

        /// Opens a reply-all on `original` and checks the quote is built from the mirrored body
        /// the composer waited for, not the preview fallback: the body is in the store, and an
        /// HTML original is quoted as its server-sanitised HTML verbatim inside
        /// `<blockquote type="cite">`, a plain one as its text with every line prefixed "> ".
        ///
        /// - Parameter expectHTML: the original was sent rich, so its HTML must be quoted.
        func openReplyExpectingQuotedBody(_ original: MessageRow, expectHTML: Bool) async throws -> ComposerModel {
            let start = Date()
            let reply = await model(.reply(messageId: original.id, mode: .all))
            timings.append(
                "reply opened (incl. body wait) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            #expect(reply.kind == .reply)
            let stored = try #require(try await session.store.body(messageId: original.id))
            if let html = stored.body.hasHtmlBody ? stored.body.html : nil {
                #expect(reply.quoteHTML?.contains("<blockquote type=\"cite\">\(html)</blockquote>") == true)
            } else {
                #expect(!expectHTML, "the original was sent rich but its mirrored body has no HTML")
                #expect(reply.quoteHTML == nil)
                let firstLine = try #require(stored.body.plainBody?.split(separator: "\n").first)
                #expect(reply.quotePlain?.contains("> \(firstLine)") == true)
            }
            return reply
        }

        /// Waits for `subject` to reach `mailbox` on the server. When the server outbox holds
        /// it with status 10 (`LocalMessage::STATUS_SMPT_SEND_FAIL`) instead, the SMTP relay
        /// refused it: delivery cannot be verified in this environment, so the parked message
        /// is deleted (cron would otherwise retry it against the relay) and the test is
        /// cancelled with that reason. Everything before delivery has been asserted by then.
        func waitForDelivery(_ what: String, in mailbox: Int64, subject: String) async throws {
            try await waitUntil(what, timeout: 120) {
                if try await !serverMessages(in: mailbox, token: subject).isEmpty { return true }
                let parked = try await client.get(.outbox).data.messages.first {
                    $0.value.subject == subject && $0.value.status == Self.smtpSendFailed
                }
                guard let parked else { return false }
                _ = try? await client.delete(.deleteOutboxMessage(id: parked.value.id))
                try Test.cancel(
                    """
                    \(what): the server's SMTP relay refused the send (outbox status 10; server log \
                    "Insufficient system storage", SMTP 452 — docs/feedback/server-findings.md). \
                    Delivery is not verifiable against this server right now.
                    """)
            }
        }

        static let smtpSendFailed = 10
    }

    /// Starts a fresh engine and mirror, runs `body`, and always stops the engine — a test
    /// that fails part-way must not leave its engine syncing the same mailboxes as the next.
    static func withLive(_ body: (Live, String) async throws -> Void) async throws {
        let live = try await live()
        do {
            try await body(live, token())
        } catch {
            await finish(live)
            throw error
        }
        await finish(live)
    }

    private static func live() async throws -> Live {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["NCMAIL_LIVE_COMPOSER"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ncmail-composer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory))
        // A bare engine, as AccountEngineLiveTests does: `AppSession` reads the Keychain, which
        // blocks behind the test host's own consent prompt.
        let session = ComposerServices(store: store, engine: AccountEngine(store: store, status: AppStatus()))
        let accountSession = AccountSession(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password))
        session.engine.start(accounts: [accountSession])
        do {
            return try await awaitMirror(session: session, client: accountSession.client, folder: folder)
        } catch {
            await session.engine.stopAll().value
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func awaitMirror(session: ComposerServices, client: MailClient, folder: URL) async throws -> Live {
        let store = session.store

        var account: AccountRecord?
        var mailboxes: [MailboxRecord] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 90 {
            if account == nil { account = try await store.accounts().first }
            if let account {
                mailboxes = try await store.mailboxes(accountId: account.id)
                let refreshed = try await store.account(id: account.id)
                if refreshed?.sentMailboxId != nil, !mailboxes.isEmpty,
                    session.engine.outbox(accountId: account.id) != nil
                {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let found = try #require(try await store.accounts().first)
        let inbox = try #require(mailboxes.first { $0.name.uppercased() == "INBOX" })
        let sent = try #require(found.sentMailboxId)
        return Live(
            session: session, account: found, client: client, folder: folder, inboxId: inbox.id, sentId: sent)
    }

    static func token() -> String { "ws27-\(UUID().uuidString.prefix(8).lowercased())" }

    /// Stops the engine and prints the timings. Printed, not recorded: an `Issue` fails the test.
    private static func finish(_ live: Live) async {
        await live.session.engine.stopAll().value
        try? FileManager.default.removeItem(at: live.folder)
        FileHandle.standardError.write(
            Data(
                "  [measured] live composer timings: \(live.timings.joined(separator: "; ")); 409 probes retried: \(live.lockedProbes)\n"
                    .utf8))
    }

    // MARK: - Compose, reply all, forward with attachments

    @Test(.enabled(if: ComposerLiveTests.serverEnvironment != nil))
    func composeReplyAllAndForwardWithAttachments() async throws {
        try await Self.withLive(Self.composeReplyAllAndForward)
    }

    private static func composeReplyAllAndForward(_ live: Live, token: String) async throws {
        // Compose with a local attachment, to myself.
        let compose = await live.model(.new(accountId: live.account.id, mailto: nil))
        #expect(compose.kind == .new)
        compose.add([live.me], to: \.to)
        compose.subject = "\(token) compose"
        // The test account's editor mode is "plaintext", which opens the composer with
        // formatting off and would send this as text only; the user turns formatting on.
        compose.document.enableFormatting()
        compose.document.setHTML("<p>WS-27 live acceptance: <b>compose</b>.</p>")
        #expect(compose.document.mode == .rich)
        let file = live.folder.appending(path: "ws27-notes.txt")
        try Data("WS-27 attachment \(token)".utf8).write(to: file)
        compose.attach(fileURLs: [file])
        try await live.waitUntil("attachment staged") { compose.attachments.count == 1 }
        await compose.send()
        #expect(compose.phase == .sending)
        try await live.waitUntil("compose left the outbox", timeout: 120) { compose.phase == .finished }
        try await live.waitForDelivery("compose in Sent", in: live.sentId, subject: "\(token) compose")

        // Reply all to it, from the mirrored Inbox copy.
        var received: MessageRow?
        try await live.waitUntil("compose mirrored in Inbox", timeout: 120) {
            received = try await live.mirrored(in: live.inboxId, token: "\(token) compose")
            return received != nil
        }
        let original = try #require(received)
        let reply = try await live.openReplyExpectingQuotedBody(original, expectHTML: true)
        #expect(reply.subject == "Re: \(token) compose")
        #expect(reply.to.map(\.key) == [live.me.key])
        reply.document.setHTML("<p>Reply-all prefill checked.</p>")
        await reply.send()
        try await live.waitForDelivery("reply in Sent", in: live.sentId, subject: "Re: \(token) compose")

        // Forward it with its attachment.
        let forward = await live.model(.forward(messageIds: [original.id], asAttachment: false))
        #expect(forward.subject == "Fwd: \(token) compose")
        try await live.waitUntil("forward attachments seeded") {
            forward.attachments.contains { $0.fileName == "ws27-notes.txt" }
        }
        forward.add([live.me], to: \.to)
        await forward.send()
        try await live.waitForDelivery("forward in Sent", in: live.sentId, subject: "Fwd: \(token) compose")
        let forwarded = try #require(
            try await live.serverMessages(in: live.sentId, token: "Fwd: \(token) compose").first)
        #expect(forwarded.value.flags.hasAttachments || !forwarded.value.attachments.isEmpty)
    }

    // MARK: - Reply quote, independent of delivery

    /// The reply quote against a WS-27 message an earlier run delivered: this proves the body
    /// wait (not the preview fallback) even while the relay refuses new sends.
    @Test(.enabled(if: ComposerLiveTests.serverEnvironment != nil))
    func replyQuotesTheMirroredOriginalBody() async throws {
        try await Self.withLive(Self.replyQuote)
    }

    private static func replyQuote(_ live: Live, token _: String) async throws {
        let delivered = try await live.serverMessages(in: live.inboxId, token: "ws27-")
            .compactMap(\.value.subject)
            .filter { $0.hasPrefix("ws27-") && $0.hasSuffix(" compose") }
        guard let subject = delivered.first else {
            try Test.cancel("No delivered WS-27 compose message in the Inbox to reply to.")
        }
        var received: MessageRow?
        try await live.waitUntil("delivered compose mirrored in Inbox", timeout: 120) {
            received = try await live.mirrored(in: live.inboxId, token: subject)
            return received != nil
        }
        // Earlier runs composed with formatting off on this plaintext account, so the
        // original may be either; the helper checks whichever it is.
        let reply = try await live.openReplyExpectingQuotedBody(try #require(received), expectHTML: false)
        #expect(reply.subject == "Re: \(subject)")
        reply.discard()
    }

    // MARK: - Autosave

    /// Typing alone, no ⌘S: the debounced write and the engine's 5 s flush land a server
    /// draft and the status reads "saved". Every autosave used to fail locally with
    /// "Error saving draft" before the engine heard of it.
    @Test(.enabled(if: ComposerLiveTests.serverEnvironment != nil))
    func typingAutosavesAServerDraft() async throws {
        try await Self.withLive(Self.autosave)
    }

    private static func autosave(_ live: Live, token: String) async throws {
        let compose = await live.model(.new(accountId: live.account.id, mailto: nil))
        compose.subject = "\(token) autosave"
        compose.document.setPlainText("Typed, never saved by hand.")
        try await live.waitUntil("autosave reached the server", timeout: 30) {
            guard let row = try await live.row(compose.draftId) else { return false }
            return row.remoteId != nil && row.syncError == nil && compose.saveStatus == .saved
        }
        let draftId = try #require(compose.draftId)
        let remoteId = try #require(try await live.row(draftId)?.remoteId)
        let stored = try await live.client.put(
            .updateDraft(id: Int(remoteId)),
            body: ComposeMessageRequest(
                accountId: Int(live.account.remoteId), subject: "\(token) autosave", isHtml: false))
        #expect(stored.data.value.subject == "\(token) autosave")

        compose.discard()
        try await live.waitUntil("autosaved draft discarded", timeout: 30) { try await live.row(draftId) == nil }
        do {
            _ = try await live.client.put(
                .updateDraft(id: Int(remoteId)),
                body: ComposeMessageRequest(accountId: Int(live.account.remoteId), subject: "probe"))
            Issue.record("server draft \(remoteId) still exists after discard")
        } catch MailError.notFound {}
    }

    // MARK: - Send later, undo

    @Test(.enabled(if: ComposerLiveTests.serverEnvironment != nil))
    func sendLaterLandsInTheOutboxAndUndoLeavesNothing() async throws {
        try await Self.withLive(Self.sendLaterAndUndo)
    }

    private static func sendLaterAndUndo(_ live: Live, token: String) async throws {
        // Send later → the mirrored Outbox, then edit it (converted to a draft, ADR-0090),
        // then delete what is left.
        let later = await live.model(.new(accountId: live.account.id, mailto: nil))
        later.add([live.me], to: \.to)
        later.subject = "\(token) later"
        later.document.setHTML("<p>Scheduled.</p>")
        let when = SendLaterPreset.tomorrowMorning.date(from: Date())
        await later.send(at: when)
        try await live.waitUntil("scheduled send in mirrored outbox", timeout: 120) {
            try await live.session.store.outboxMessages().contains { $0.subject == "\(token) later" }
        }
        let scheduled = try #require(
            try await live.session.store.outboxMessages().first { $0.subject == "\(token) later" })
        #expect(scheduled.sendAt == Int64(when.timeIntervalSince1970))
        let items = try await live.session.store.outboxMessages().map(OutboxItem.init)
        #expect(items.first { $0.subject == "\(token) later" }?.status == .pending)

        let edit = await live.model(.outbox(outboxId: try #require(scheduled.id)))
        #expect(edit.kind == .outbox)
        #expect(edit.sendAt == when)
        await edit.cancelOutboxIfSafe()
        try await live.waitUntil("outbox entry paused (cancelled)", timeout: 60) {
            try await !live.session.store.outboxMessages().contains { $0.subject == "\(token) later" }
        }
        edit.discard()

        // Undo inside the window: nothing reaches the server.
        let undo = await live.model(.new(accountId: live.account.id, mailto: nil))
        undo.add([live.me], to: \.to)
        undo.subject = "\(token) undo"
        undo.document.setHTML("<p>Undone.</p>")
        await undo.send()
        let draftId = try #require(undo.draftId)
        let outbox = try #require(live.session.engine.outbox(accountId: live.account.id))
        let undone = await outbox.undoSend(draftId: draftId)
        #expect(undone)
        try await live.waitUntil("composer back to editing") { undo.phase == .editing }
        try await Task.sleep(for: .seconds(12))
        #expect(try await live.row(draftId)?.sendState == nil)
        #expect(try await live.serverMessages(in: live.sentId, token: "\(token) undo").isEmpty)
        undo.discard()
        try await live.waitUntil("undone draft discarded", timeout: 30) { try await live.row(draftId) == nil }
    }

    // MARK: - Offline

    @Test(.enabled(if: ComposerLiveTests.serverEnvironment != nil))
    func offlineComposeAndSendDrainOnReconnect() async throws {
        try await Self.withLive(Self.offlineComposeAndSend)
    }

    private static func offlineComposeAndSend(_ live: Live, token: String) async throws {
        live.session.engine.apply(conditions: NetworkConditions(isOffline: true))
        let offline = await live.model(.new(accountId: live.account.id, mailto: nil))
        offline.add([live.me], to: \.to)
        offline.subject = "\(token) offline"
        offline.document.setHTML("<p>Written and sent offline.</p>")
        await offline.send()
        let draftId = try #require(offline.draftId)
        // Past the undo window the send waits in the row.
        try await Task.sleep(for: .seconds(13))
        #expect(try await live.row(draftId)?.sendState == "queued")
        #expect(try await live.serverMessages(in: live.sentId, token: "\(token) offline").isEmpty)

        live.session.engine.apply(conditions: NetworkConditions(isOffline: false))
        try await live.waitUntil("offline send drained", timeout: 120) { offline.phase == .finished }
        try await live.waitForDelivery("offline send in Sent", in: live.sentId, subject: "\(token) offline")
    }
}
