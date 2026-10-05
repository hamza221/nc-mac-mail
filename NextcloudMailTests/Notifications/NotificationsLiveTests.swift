// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// WS-41's acceptance — "a mail sent from the web client notifies within one sync cycle" —
/// against a live server, with the one substitution the dev stack forces: its SMTP relay
/// refuses delivery (452), so the new inbox row comes from moving an existing message into
/// INBOX through the Mail API instead. To the sync pass and to the notifier that is exactly
/// a new message: a row the server lists under a new id.
///
/// The whole app engine runs; only the notification center is the test's fake, because the
/// real one refuses an unsigned runner.
///
/// Off by default (sockets; definition-of-done.md). `localhost`, not `nextcloud.local`.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_NOTIFY=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/NotificationsLiveTests test
/// ```
@Suite("Notifications against a live server", .serialized)
@MainActor
struct NotificationsLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_NOTIFY"]

    enum LiveError: Error { case missingEnvironment, timedOut(String) }

    @Test(.enabled(if: NotificationsLiveTests.serverEnvironment != nil), .timeLimit(.minutes(5)))
    func aMessageArrivingInTheInboxNotifiesWithinOneSyncCycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_NOTIFY"], let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"], let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ws41-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory))
        let engine = AccountEngine(store: store, status: AppStatus())
        defer { engine.stopAll() }
        let session = AccountSession(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password))
        engine.start(accounts: [session])

        let clock = ContinuousClock()
        let started = clock.now
        let account = try await eventually("account") { try await store.accounts().first }
        let inbox = try await eventually("inbox enumerated", within: 180) {
            try await store.mailboxes(accountId: account.id).first {
                $0.specialRole == "inbox" && $0.envelopesComplete
            }
        }
        let mirrored = clock.now - started

        let center = FakeNotificationCenter()
        let defaults = try #require(UserDefaults(suiteName: "ws41-live-\(UUID().uuidString)"))
        let notifier = MailNotifier(store: store, center: center, defaults: defaults)
        defer { notifier.stop() }
        notifier.start(navigation: NavigationState(store: store), queue: { engine.mutationQueue(accountId: $0) })
        _ = try await eventually("baseline") { notifier.watermark(mailboxId: inbox.id) }
        #expect(center.requests.isEmpty, "the initial mirror must not notify")

        // A message from another mailbox, made unread and moved into INBOX on the server.
        let source = try await eventually("a message outside the inbox", within: 120) { () -> MessageRecord? in
            // Not Drafts: a draft never notifies, whichever mailbox it is in.
            let excluded: Set<String> = ["inbox", "drafts", "trash", "junk"]
            for mailbox in try await store.mailboxes(accountId: account.id)
            where !excluded.contains(mailbox.specialRole ?? "") && mailbox.isSelectable {
                for id in try await store.messageIds(mailboxId: mailbox.id).reversed() {
                    if let message = try await store.message(id: id), !message.isDraft { return message }
                }
            }
            return nil
        }
        let sourceMailbox = try #require(try await store.mailbox(id: source.mailboxId))
        _ = try await session.client.put(
            .setFlags(messageId: Int(source.remoteId)), body: SetFlagsRequest(flags: ["seen": false]))
        _ = try await session.client.post(
            .moveMessage(id: Int(source.remoteId)), body: MoveMessageRequest(destFolderId: Int(inbox.remoteId)))

        // One sync cycle of the inbox: what the scheduler runs on its own every interval.
        let moved = clock.now
        engine.refresh(mailboxId: inbox.id, accountId: account.id)
        let request: MailNotificationRequest
        do {
            request = try await eventually("banner", within: 60) { center.requests.first }
        } catch {
            var arrivals: [String] = []
            for id in try await store.messageIds(mailboxId: inbox.id).suffix(3) {
                guard let row = try await store.message(id: id) else { continue }
                arrivals.append(
                    "id \(id) seen \(row.isSeen) draft \(row.isDraft) same \(row.messageId == source.messageId)")
            }
            Self.report(
                "no banner; watermark \(String(describing: notifier.watermark(mailboxId: inbox.id))); newest inbox rows: \(arrivals)"
            )
            throw error
        }
        let latency = clock.now - moved

        #expect(center.requests.count == 1)
        #expect(request.category == .message || request.category == .messageWithoutArchive)
        let arrivedId = try #require(request.messageId)
        let arrived = try #require(try await store.message(id: arrivedId))
        #expect(arrived.mailboxId == inbox.id)
        #expect(request.body == (arrived.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "No subject"))

        // Put the server back the way it was.
        _ = try await session.client.post(
            .moveMessage(id: Int(arrived.remoteId)),
            body: MoveMessageRequest(destFolderId: Int(sourceMailbox.remoteId)))
        if let back = try? await eventuallyMovedBack(store, session: session, source: source, mailbox: sourceMailbox),
            source.isSeen
        {
            _ = try? await session.client.put(
                .setFlags(messageId: Int(back)), body: SetFlagsRequest(flags: ["seen": true]))
        }

        Self.report("inbox enumerated in \(mirrored); banner \(latency) after the server-side move, one refresh")
    }

    /// The moved-back copy's new server id, found by its Message-ID in the source mailbox's
    /// newest page.
    private func eventuallyMovedBack(
        _ store: MailStore, session: AccountSession, source: MessageRecord, mailbox: MailboxRecord
    ) async throws -> Int64? {
        let page = try await session.client.get(.messages(mailboxId: Int(mailbox.remoteId), limit: 20))
        return page.first { $0.value.messageId == source.messageId }.map { Int64($0.value.id) }
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("  [measured] live WS-41: \(line)\n".utf8))
    }

    private func eventually<Value>(
        _ what: String, within seconds: Double = 30, _ read: () async throws -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let value = try await read() { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LiveError.timedOut(what)
    }
}
