// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// Records what would have been shown. `UNUserNotificationCenter` refuses an unsigned test
/// runner, which is why ``MailNotificationCenter`` exists.
@MainActor
final class FakeNotificationCenter: MailNotificationCenter {
    private(set) var requests: [MailNotificationRequest] = []
    private(set) var removed: [String] = []
    private(set) var isActive = false

    func activate(onResponse: @escaping @Sendable (MailNotificationResponse) async -> Void) {
        isActive = true
    }

    func add(_ request: MailNotificationRequest) async {
        requests.append(request)
    }

    func removeDelivered(identifiers: [String]) {
        removed.append(contentsOf: identifiers)
    }
}

@Suite("MailNotifier")
@MainActor
struct MailNotifierTests {
    enum Timeout: Error { case timedOut(String) }

    private struct Fixture {
        let mirror: TriageMirror
        let notifier: MailNotifier
        let center: FakeNotificationCenter
        let navigation: NavigationState
        let defaults: UserDefaults
        var badges: [String?] { badgeLog.values }
        let badgeLog: BadgeLog
    }

    @MainActor
    final class BadgeLog {
        var values: [String?] = []
    }

    /// Mutable state a `@MainActor` closure can capture: those closures are `Sendable`, so a
    /// captured `var` would not compile.
    @MainActor
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func fixture(accounts: [TriageMirror.Roles] = [.all]) async throws -> Fixture {
        let mirror = try await TriageMirror.seed(accounts: accounts)
        let center = FakeNotificationCenter()
        let defaults = try #require(UserDefaults(suiteName: "ws41-\(UUID().uuidString)"))
        let notifier = MailNotifier(store: mirror.store, center: center, defaults: defaults)
        let log = BadgeLog()
        notifier.setBadge = { log.values.append($0) }
        notifier.activateApp = {}
        let navigation = NavigationState(store: mirror.store)
        return Fixture(
            mirror: mirror, notifier: notifier, center: center, navigation: navigation, defaults: defaults,
            badgeLog: log)
    }

    private func start(_ f: Fixture) {
        let store = f.mirror.store
        f.notifier.start(navigation: f.navigation, queue: { _ in MutationQueue(store: store) })
    }

    /// The inbox's envelope enumeration finished: what the mirror writes at the end of stage 1.
    private func completeEnumeration(_ f: Fixture, _ account: TriageMirror.Account) async throws {
        try await f.mirror.store.setEnvelopeCursor(nil, complete: true, mailboxId: account.inboxId, lastSyncAt: 1)
    }

    /// Clock-bound, like the other suites' waits: observations deliver on the main actor,
    /// which a full parallel run shares with every `@MainActor` suite, and a baseline was
    /// measured missing a five-second bound there. Only a failing run waits this long.
    private func eventually(
        _ what: String, within seconds: Double = 10, _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Timeout.timedOut(what)
    }

    /// Long enough for every observation to have delivered and every scan to have finished,
    /// for the assertions that something did *not* happen.
    private func quiet() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - New mail

    @Test func aRowInsertedAfterTheInitialMirrorNotifiesOnce() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        try await f.mirror.addMessages(count: 3, account: account)
        start(f)
        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }

        let ids = try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 100)
        try await eventually("banner") { !f.center.requests.isEmpty }
        try await quiet()

        #expect(f.center.requests.count == 1)
        let request = try #require(f.center.requests.first)
        #expect(request.identifier == "message-\(ids[0])")
        #expect(request.title == "Name redacted")
        #expect(request.body == "Subject redacted")
        #expect(request.category == .message)
        #expect(request.messageId == ids[0])
        #expect(request.threadIdentifier == "\(account.id)|<thread-\(account.id)-100@example.invalid>")
    }

    @Test func theFirstSyncNeverNotifies() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        start(f)
        // The whole initial enumeration lands while the gate is closed.
        try await f.mirror.addMessages(count: 40, account: account)
        try await quiet()
        #expect(f.center.requests.isEmpty)

        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }
        try await quiet()
        #expect(f.center.requests.isEmpty)

        // Then only what arrives afterwards.
        let ids = try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 500)
        try await eventually("banner") { !f.center.requests.isEmpty }
        try await quiet()
        #expect(f.center.requests.map(\.messageId) == [ids[0]])
    }

    @Test func aBigBatchBecomesOneSummary() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        start(f)
        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }

        try await f.mirror.addMessages(count: MailNotifier.individualLimit + 1, account: account, firstRemoteId: 200)
        try await eventually("summary") { !f.center.requests.isEmpty }
        try await quiet()
        #expect(f.center.requests.count == 1)
        #expect(f.center.requests.first?.category == .summary)
        #expect(f.center.requests.first?.mailboxId == account.inboxId)
    }

    @Test func readAndClosedGateRowsStayQuiet() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        start(f)
        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }

        // Already read elsewhere before this Mac synced it.
        try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 300, seen: true)
        // A re-enumeration closes the gate again; what it writes is not new mail.
        try await f.mirror.store.setEnvelopeCursor(nil, complete: false, mailboxId: account.inboxId, lastSyncAt: 2)
        try await eventually("gate closed") { f.notifier.watermark(mailboxId: account.inboxId) == nil }
        try await f.mirror.addMessages(count: 3, account: account, firstRemoteId: 400)
        try await quiet()
        #expect(f.center.requests.isEmpty)
    }

    @Test func anAccountWithoutArchiveGetsNoArchiveAction() async throws {
        let f = try await fixture(accounts: [.none])
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        start(f)
        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }
        try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 10)
        try await eventually("banner") { !f.center.requests.isEmpty }
        #expect(f.center.requests.first?.category == .messageWithoutArchive)
    }

    // MARK: - Suppression

    @Test func theKeyMainWindowShowingTheInboxSuppresses() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        let isKey = Box(true)
        // `notify` asks this once per batch, at the moment it decides between a banner and
        // silence, so the count is when the suppression was decided rather than a guess.
        let asked = Box(0)
        f.notifier.isMainWindowKey = {
            asked.value += 1
            return isKey.value
        }
        f.navigation.select(.mailbox(account.inboxId))
        start(f)
        try await completeEnumeration(f, account)
        try await eventually("baseline") { f.notifier.watermark(mailboxId: account.inboxId) != nil }

        try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 600)
        // Flipping the window before that decision would race it: a scan slowed by a busy
        // run would then see another app frontmost and banner the row meant to be silent.
        try await eventually("suppression decided") { asked.value == 1 }
        #expect(f.center.requests.isEmpty)

        // The same inbox, but another app is frontmost.
        isKey.value = false
        let ids = try await f.mirror.addMessages(count: 1, account: account, firstRemoteId: 601)
        try await eventually("banner") { !f.center.requests.isEmpty }
        try await quiet()
        #expect(f.center.requests.map(\.messageId) == [ids[0]])
        #expect(asked.value == 2)
    }

    @Test func suppressionFollowsTheSelection() async throws {
        let f = try await fixture(accounts: [.all, .all])
        defer { f.notifier.stop() }
        start(f)
        let first = f.mirror.accounts[0].inboxId
        let second = f.mirror.accounts[1].inboxId
        f.notifier.isMainWindowKey = { true }

        f.navigation.select(.mailbox(first))
        #expect(f.notifier.isShowing(mailboxId: first))
        #expect(!f.notifier.isShowing(mailboxId: second))
        f.navigation.select(.unifiedInbox)
        #expect(f.notifier.isShowing(mailboxId: first) && f.notifier.isShowing(mailboxId: second))
        f.navigation.select(.priorityInbox)
        #expect(f.notifier.isShowing(mailboxId: second))
        f.navigation.select(.outbox)
        #expect(!f.notifier.isShowing(mailboxId: first))

        f.navigation.select(.mailbox(first))
        f.notifier.isMainWindowKey = { false }
        #expect(!f.notifier.isShowing(mailboxId: first))
    }

    // MARK: - Dock badge

    @Test func theBadgeAddsEveryAccountsInbox() async throws {
        #expect(DockBadge.label(unread: [3, 4]) == "7")
        #expect(DockBadge.label(unread: [0, 0]) == nil)
        #expect(DockBadge.label(unread: []) == nil)

        let f = try await fixture(accounts: [.none, .none])
        defer { f.notifier.stop() }
        start(f)
        try await setInboxUnread(f, account: 0, remoteInbox: 1, count: 3)
        try await setInboxUnread(f, account: 1, remoteInbox: 101, count: 4)
        try await eventually("badge 7") { f.badges.last == .some("7") }

        try await setInboxUnread(f, account: 0, remoteInbox: 1, count: 0)
        try await eventually("badge 4") { f.badges.last == .some("4") }
        try await setInboxUnread(f, account: 1, remoteInbox: 101, count: 0)
        try await eventually("badge cleared") { f.badges.last == .some(nil) }
    }

    /// The server's count, which is what the sidebar shows until the inbox is mirrored.
    private func setInboxUnread(_ f: Fixture, account index: Int, remoteInbox: Int64, count: Int) async throws {
        let account = f.mirror.accounts[index]
        try await f.mirror.store.upsert(
            mailboxes: [
                MailboxWrite(
                    accountId: account.id, remoteId: remoteInbox, name: "INBOX", delimiter: ".",
                    displayName: "INBOX", specialRole: "inbox", isSubscribed: true, unreadCount: count)
            ],
            accountId: account.id)
    }

    // MARK: - Responses

    @Test func archiveFromTheBannerIsQueuedOffline() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        // No drainer at all: the queue writes the row and nothing sends it.
        start(f)
        let ids = try await f.mirror.addMessages(count: 1, account: account)

        await f.notifier.handle(MailNotificationResponse(action: .archive, messageId: ids[0], accountId: account.id))

        #expect(try await f.mirror.message(ids[0])?.mailboxId == account.archiveId)
        #expect(try await f.mirror.queueDepth(account) == 1)
        #expect(f.center.removed == ["message-\(ids[0])"])
    }

    @Test func markReadFromTheBannerIsQueued() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let account = f.mirror.accounts[0]
        start(f)
        let ids = try await f.mirror.addMessages(count: 1, account: account)

        await f.notifier.handle(MailNotificationResponse(action: .markRead, messageId: ids[0], accountId: account.id))

        #expect(try await f.mirror.message(ids[0])?.isSeen == true)
        #expect(try await f.mirror.queueDepth(account) == 1)
    }

    @Test func replyOpensTheComposerEvenWhenItArrivesFirst() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        let opened = Box<[ComposeRequest]>([])
        let messages = Box<[Int64]>([])

        // The banner launched the app: no window has handed over `openComposer` yet.
        await f.notifier.handle(MailNotificationResponse(action: .reply, messageId: 42))
        #expect(opened.value.isEmpty)
        f.notifier.openComposer = { opened.value.append($0) }
        f.notifier.openMessage = { messages.value.append($0) }
        try await eventually("composer") { !opened.value.isEmpty }
        #expect(opened.value == [.reply(messageId: 42, mode: .sender)])

        await f.notifier.handle(MailNotificationResponse(action: .open, messageId: 7))
        #expect(messages.value == [7])
    }

    @Test func systemResponsesMapToActions() {
        let info: [AnyHashable: Any] = ["messageId": NSNumber(value: 5), "accountId": NSNumber(value: 2)]
        #expect(
            SystemNotificationCenter.response(actionIdentifier: "mail.archive", userInfo: info)
                == MailNotificationResponse(action: .archive, messageId: 5, accountId: 2))
        #expect(
            SystemNotificationCenter.response(actionIdentifier: "mail.markRead", userInfo: info)?.action == .markRead)
        #expect(SystemNotificationCenter.response(actionIdentifier: "mail.reply", userInfo: info)?.action == .reply)
        #expect(
            SystemNotificationCenter.response(
                actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info)?.action == .open)
        #expect(
            SystemNotificationCenter.response(
                actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", userInfo: info) == nil)
    }

    // MARK: - Nextcloud notifications

    /// The notifications app's documented OCS shape (`docs/ocs-endpoint-v2.md` in
    /// nextcloud/notifications). Not recorded: the dev server does not ship the app, and its
    /// route answers 404 — see the WS-41 report.
    private static let noticesBody = Data(
        """
        {"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[
        {"notification_id":61,"app":"mail","user":"admin","datetime":"2026-10-04T10:00:00+00:00",
         "object_type":"account","object_id":"1","subject":"Your mailbox is almost full",
         "message":"95% of the quota is used.","link":"http://localhost/index.php/apps/mail/","icon":""},
        {"notification_id":62,"app":"files_sharing","user":"admin","datetime":"2026-10-04T10:00:00+00:00",
         "object_type":"share","object_id":"9","subject":"Someone shared a file","message":"","link":"","icon":""}
        ]}}
        """.utf8)

    private func poller(_ f: Fixture, _ transport: ReplayTransport) throws -> ServerNotificationPoller {
        let server = try #require(URL(string: "https://server0.example.invalid/"))
        return ServerNotificationPoller(
            store: f.mirror.store,
            client: MailClient(
                server: server, credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
                transport: transport, retryPolicy: .none),
            identity: ServerIdentity(serverURL: "https://server0.example.invalid/", loginName: "lorelai"))
    }

    @Test func mailNoticesBecomeBannersOnce() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        start(f)
        let poller = try poller(f, .replaying(Self.noticesBody))

        await poller.poll()
        try await eventually("notice banner") { !f.center.requests.isEmpty }
        let request = try #require(f.center.requests.first)
        #expect(request.category == .server)
        #expect(request.title == "Your mailbox is almost full")
        #expect(request.body == "95% of the quota is used.")
        #expect(request.link == URL(string: "http://localhost/index.php/apps/mail/"))

        // The next poll lists the same notice: shown once, ever.
        await poller.poll()
        try await quiet()
        #expect(f.center.requests.count == 1)
        #expect(f.defaults.stringArray(forKey: MailNotifier.shownNoticesKey)?.count == 1)
    }

    @Test(arguments: [ReplayTransport.answering(status: 500), .answering(status: 404), .offline])
    func aFailedPollStaysQuiet(_ transport: ReplayTransport) async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        start(f)
        let poller = try poller(f, transport)
        await poller.poll()
        await poller.poll()
        try await quiet()
        #expect(f.center.requests.isEmpty)
        let loginId = try #require(
            try await f.mirror.store.ensureLogin(
                ServerIdentity(serverURL: "https://server0.example.invalid/", loginName: "lorelai")
            ).id)
        #expect(
            try await f.mirror.store.serverResult(
                kind: ServerNotificationPoller.kind, key: ServerNotificationPoller.key, loginId: loginId) == nil)
    }

    @Test func anOfflinePollerSendsNothing() async throws {
        let f = try await fixture()
        defer { f.notifier.stop() }
        start(f)
        let poller = try poller(f, .replaying(Self.noticesBody))
        await poller.apply(conditions: MirrorConditions(isOffline: true))
        await poller.poll()
        try await quiet()
        #expect(f.center.requests.isEmpty)
    }
}
