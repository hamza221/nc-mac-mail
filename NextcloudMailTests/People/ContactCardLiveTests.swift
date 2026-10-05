// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// WS-26's live acceptance: "Add to contact" and "New contact" made offline sit in the queue,
/// then reach the server — what web Contacts reads — when the drainer runs.
///
/// ```
/// TEST_RUNNER_NCMAIL_LIVE_PEOPLE=http://localhost TEST_RUNNER_NCMAIL_LIVE_USER=admin \
///   TEST_RUNNER_NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/ContactCardLiveTests test
/// ```
///
/// The card is created in the login's default "Contacts" book so it can be seen in web
/// Contacts; it is deleted at the end unless `TEST_RUNNER_NCMAIL_LIVE_KEEP=1`.
@Suite("Contact card against a live server", .serialized)
@MainActor
struct ContactCardLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_PEOPLE"]

    @Test(.enabled(if: serverEnvironment != nil), .timeLimit(.minutes(3)))
    func offlineNewContactAndAddToContactReachTheServerAfterDrain() async throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try #require(environment["NCMAIL_LIVE_PEOPLE"].flatMap(URL.init(string:)))
        let credentials = BasicCredentials(
            loginName: try #require(environment["NCMAIL_LIVE_USER"]),
            appPassword: try #require(environment["NCMAIL_LIVE_PASSWORD"]))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ws26-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MailStore(url: folder.appending(path: "mirror.sqlite"))

        let dav = DAVClient(server: server, credentials: credentials)
        let mail = MailClient(server: server, credentials: credentials, clientVersion: "ws26-live")
        let identity = ServerIdentity(serverURL: server, loginName: credentials.loginName)
        _ = try await MirrorCoordinator.discoverAccounts(store: store, client: mail, identity: identity)
        let loginId = try #require(try await store.ensureLogin(identity).id)

        let handler = ContactWriteHandler(store: store, client: dav)
        let configuration = MutationQueueConfiguration(dav: handler)
        let queue = MutationQueue(store: store, configuration: configuration)
        let sync = ContactsSync(
            store: store, client: dav, loginId: loginId,
            pendingWrites: { try await queue.pendingDAVWrites(loginId: loginId) })
        _ = try await sync.runPass()
        let book = try #require(
            try await store.addressBooks(loginId: loginId).first {
                $0.sharedBy == nil && !$0.isReadOnly && $0.url.hasSuffix("/contacts/")
            })

        // Offline: no drainer runs. Both writes land locally and wait in the queue.
        let uid = "ws26-live-\(UUID().uuidString)"
        let email = "\(uid)@example.org"
        let started = ContinuousClock.now
        try await ContactCardActions.create(
            name: "WS26 Live Person", email: email, in: book, loginId: loginId, queue: queue, uid: uid)
        let created = try #require(try await store.contacts(withEmail: email).first)
        let added = try await ContactCardActions.add(
            email: "second-\(email)", toContact: try #require(created.id), loginId: loginId, store: store, queue: queue)
        let queuedElapsed = ContinuousClock.now - started
        #expect(added)
        let pending = try await queue.pendingDAVWrites(loginId: loginId)
        #expect(pending.count >= 1)
        #expect(try await store.contacts(withEmail: "second-\(email)").count == 1)

        // Reconnect: the drainer sends the queue.
        let accountId = try await queue.queueAccountId(loginId: loginId)
        let drainer = OperationDrainer(store: store, client: mail, accountId: accountId, configuration: configuration)
        let drainStart = ContinuousClock.now
        await drainer.drain()
        let drainElapsed = ContinuousClock.now - drainStart

        let href = try #require(ContactCardActions.newHref(bookURL: book.url, uid: uid))
        let bookURL = try #require(URL(string: book.url))
        let onServer = try #require(try await dav.addressbookMultiget(bookURL, hrefs: [href]).first?.addressData)
        let queuedAfter = try await queue.pendingDAVWrites(loginId: loginId)
        if environment["NCMAIL_LIVE_KEEP"] != "1" {
            try await dav.delete(dav.resolve(href: href))
        }

        FileHandle.standardError.write(
            Data(
                "  [measured] live WS-26: queued offline in \(queuedElapsed), \(pending.count) pending; drained in \(drainElapsed)\n"
                    .utf8))
        #expect(onServer.contains("FN:WS26 Live Person"))
        #expect(onServer.contains(email))
        #expect(onServer.contains("second-\(email)"))
        #expect(queuedAfter.isEmpty)
    }
}
