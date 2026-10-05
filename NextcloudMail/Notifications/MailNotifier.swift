// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailStore
import NCMailSync
import OSLog

/// New-mail banners, Nextcloud notifications of the Mail app, and the Dock badge (WS-41).
///
/// Everything here reads the mirror; the network only ever wrote it. New mail is a row the
/// sync inserted into an inbox *after* that inbox's envelopes were first enumerated
/// ([ADR-0098](../../docs/decisions/0098-new-mail-notifications-gate-on-the-inbox-enumeration.md)):
/// per inbox, the notifier waits for `mailbox.envelopesComplete`, takes the highest message id
/// as its watermark, and from then on every unread row above the watermark is new. The first
/// sync of an account therefore never notifies, and neither does a re-enumeration — the gate
/// closes again whenever the column goes back to false.
///
/// Banner actions go through the mutation queue, the same door the toolbar uses, so Archive
/// and Mark as read work offline and drain with everything else.
@MainActor
final class MailNotifier {
    /// More new messages than this from one sync pass of one inbox become a single "N new
    /// messages" banner: a Mac that slept through a day of mail does not get a wall of them.
    static let individualLimit = 5

    /// Set by ``MailNotifierHooks`` from the main window's environment. A Reply clicked before
    /// it is set (the banner launched the app) waits for it.
    var openComposer: (@MainActor (ComposeRequest) -> Void)? {
        didSet { flushPending() }
    }
    var openMessage: (@MainActor (Int64) -> Void)? {
        didSet { flushPending() }
    }
    /// Whether a main window is key. Replaceable so a test can say so without a window.
    var isMainWindowKey: @MainActor () -> Bool
    var activateApp: @MainActor () -> Void = { NSApp.activate() }
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var setBadge: @MainActor (String?) -> Void {
        get { badge.setLabel }
        set { badge.setLabel = newValue }
    }

    private let store: MailStore
    private let center: any MailNotificationCenter
    private let defaults: UserDefaults
    private let badge: DockBadge
    private weak var navigation: NavigationState?
    private var queue: @MainActor (Int64) -> MutationQueue
    private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    private final class Inbox {
        let mailboxId: Int64
        var gateOpen = false
        var watermark: Int64?
        var lastCounts: (messages: Int, unread: Int)?
        var scanning = false
        var rescan = false
        var tasks: [Task<Void, Never>] = []

        init(mailboxId: Int64) { self.mailboxId = mailboxId }
    }

    private var inboxes: [Int64: Inbox] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var pending: [MailNotificationResponse] = []

    nonisolated static let shownNoticesKey = "MailNotifier.shownServerNotices"
    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "notifications")

    init(store: MailStore, center: any MailNotificationCenter, defaults: UserDefaults = .standard) {
        self.store = store
        self.center = center
        self.defaults = defaults
        badge = DockBadge(store: store)
        queue = { _ in MutationQueue(store: store) }
        isMainWindowKey = { false }
        isMainWindowKey = { [weak self] in
            guard let self, NSApp.isActive else { return false }
            return mainWindows.allObjects.contains { $0.isKeyWindow }
        }
        // Now rather than in `start`: a banner clicked while the app was not running is
        // delivered to whoever is the delegate as the app finishes launching.
        center.activate { [weak self] response in
            await self?.handle(response)
        }
    }

    /// - Parameters:
    ///   - navigation: what the sidebar shows, for the "already on screen" suppression.
    ///   - queue: the account's mutation queue (`AccountEngine.mutationQueue(accountId:)`).
    func start(navigation: NavigationState, queue: @escaping @MainActor (Int64) -> MutationQueue) {
        guard tasks.isEmpty else { return }
        self.navigation = navigation
        self.queue = queue
        badge.start()
        tasks.append(
            Task { [weak self, store] in
                do {
                    for try await ids in store.observeInboxMailboxIds() {
                        self?.watch(inboxes: ids)
                    }
                } catch {
                    Self.logger.error("inbox observation stopped: \(String(describing: error), privacy: .public)")
                }
            })
        tasks.append(
            Task { [weak self, store] in
                do {
                    for try await rows in store.observeServerResults(
                        kind: ServerNotificationPoller.kind, keys: [ServerNotificationPoller.key])
                    {
                        await self?.post(serverRows: rows)
                    }
                } catch {
                    Self.logger.error("notice observation stopped: \(String(describing: error), privacy: .public)")
                }
            })
    }

    /// For tests: everything stops.
    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for inbox in inboxes.values { inbox.tasks.forEach { $0.cancel() } }
        inboxes.removeAll()
        badge.stop()
    }

    /// The main window's `NSWindow`, from ``MailNotifierHooks``. Weakly held; a closed window
    /// simply drops out.
    func register(mainWindow: NSWindow) {
        mainWindows.add(mainWindow)
    }

    // MARK: - New mail

    private func watch(inboxes ids: [Int64]) {
        let wanted = Set(ids)
        for (id, inbox) in inboxes where !wanted.contains(id) {
            inbox.tasks.forEach { $0.cancel() }
            inboxes[id] = nil
        }
        for id in ids where inboxes[id] == nil {
            let inbox = Inbox(mailboxId: id)
            inboxes[id] = inbox
            inbox.tasks.append(
                Task { [weak self, store] in
                    do {
                        for try await mailbox in store.observeMailbox(id: id) {
                            self?.gate(inbox, open: mailbox?.envelopesComplete == true)
                        }
                    } catch {
                        Self.logger.error(
                            "inbox gate observation stopped: \(String(describing: error), privacy: .public)")
                    }
                })
            inbox.tasks.append(
                Task { [weak self, store] in
                    do {
                        for try await counts in store.observeMailboxCounts(mailboxId: id) {
                            self?.counted(inbox, counts)
                        }
                    } catch {
                        Self.logger.error(
                            "inbox count observation stopped: \(String(describing: error), privacy: .public)")
                    }
                })
        }
    }

    /// Nil until the inbox's gate opened and its baseline was read; a test waits on this
    /// before inserting the row that should notify.
    func watermark(mailboxId: Int64) -> Int64? {
        inboxes[mailboxId]?.watermark
    }

    private func gate(_ inbox: Inbox, open: Bool) {
        guard open != inbox.gateOpen else { return }
        inbox.gateOpen = open
        // A closed gate forgets its watermark, so the next opening re-baselines instead of
        // treating a whole re-enumeration as new mail.
        if !open { inbox.watermark = nil }
        Task { await scan(inbox) }
    }

    /// Only the two counts an insert moves: the backfill changes `bodiesPresent` once per
    /// body, and a scan per body would be a full id read per body.
    private func counted(_ inbox: Inbox, _ counts: MailboxCounts) {
        let pair = (messages: counts.messageCount, unread: counts.unreadCount)
        if let last = inbox.lastCounts, last == pair { return }
        inbox.lastCounts = pair
        Task { await scan(inbox) }
    }

    private func scan(_ inbox: Inbox) async {
        guard inbox.gateOpen else { return }
        guard !inbox.scanning else {
            inbox.rescan = true
            return
        }
        inbox.scanning = true
        defer { inbox.scanning = false }
        repeat {
            inbox.rescan = false
            let ids: [Int64]
            do {
                ids = try await store.messageIds(mailboxId: inbox.mailboxId)
            } catch {
                Self.logger.error("inbox scan failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard inbox.gateOpen, inboxes[inbox.mailboxId] === inbox else { return }
            let highest = ids.last ?? 0
            guard let watermark = inbox.watermark else {
                inbox.watermark = highest
                continue
            }
            inbox.watermark = max(watermark, highest)
            let fresh = ids.filter { $0 > watermark }
            if !fresh.isEmpty { await notify(fresh, mailboxId: inbox.mailboxId) }
        } while inbox.rescan
    }

    private func notify(_ ids: [Int64], mailboxId: Int64) async {
        var messages: [MessageRecord] = []
        for id in ids {
            guard let message = try? await store.message(id: id), !message.isSeen, !message.isDraft else { continue }
            messages.append(message)
        }
        guard let first = messages.first else { return }
        if isShowing(mailboxId: mailboxId) {
            Self.logger.debug("\(messages.count, privacy: .public) new message(s) on screen; no banner")
            return
        }
        if messages.count > Self.individualLimit {
            await center.add(await summary(count: messages.count, accountId: first.accountId, mailboxId: mailboxId))
            return
        }
        let hasArchive = await archiveMailbox(accountId: first.accountId) != nil
        for message in messages {
            await center.add(Self.request(for: message, hasArchive: hasArchive))
        }
    }

    /// The main window is key and shows this inbox — alone, or inside the unified or the
    /// priority inbox, which list every inbox's mail.
    func isShowing(mailboxId: Int64) -> Bool {
        guard isMainWindowKey(), let selection = navigation?.selection else { return false }
        switch selection {
        case .mailbox(let id): return id == mailboxId
        case .unifiedInbox, .priorityInbox: return true
        case .favorites, .outbox, .contacts: return false
        }
    }

    nonisolated static func request(for message: MessageRecord, hasArchive: Bool) -> MailNotificationRequest {
        let sender = [message.fromLabel, message.fromEmail].compactMap { $0 }.first { !$0.isEmpty }
        let subject = message.subject.flatMap { $0.isEmpty ? nil : $0 }
        return MailNotificationRequest(
            identifier: "message-\(message.id)",
            title: sender ?? String(localized: "Unknown sender"),
            body: subject ?? String(localized: "No subject"),
            threadIdentifier: "\(message.accountId)|\(message.threadRootId ?? "message-\(message.id)")",
            category: hasArchive ? .message : .messageWithoutArchive,
            messageId: message.id,
            accountId: message.accountId,
            mailboxId: message.mailboxId
        )
    }

    private func summary(count: Int, accountId: Int64, mailboxId: Int64) async -> MailNotificationRequest {
        let account = try? await store.account(id: accountId)
        return MailNotificationRequest(
            identifier: "summary-\(mailboxId)-\(UUID().uuidString)",
            title: account?.emailAddress ?? String(localized: "Mail"),
            body: String(localized: "\(count) new messages"),
            threadIdentifier: "\(accountId)|summary",
            category: .summary,
            accountId: accountId,
            mailboxId: mailboxId
        )
    }

    private func archiveMailbox(accountId: Int64) async -> Int64? {
        try? await queue(accountId).localMailboxId(for: .archive, accountId: accountId)
    }

    // MARK: - Nextcloud notifications

    /// Each Mail-app notice is shown once, ever: the ids already shown are kept in
    /// `UserDefaults` (they are this Mac's display state, not mirror data), pruned to what
    /// the server still lists so the set cannot grow without bound.
    private func post(serverRows rows: [ServerResultRecord]) async {
        var shown = Set(defaults.stringArray(forKey: Self.shownNoticesKey) ?? [])
        var present: Set<String> = []
        var reported: Set<Int64> = []
        for row in rows {
            guard let notices = try? JSONDecoder().decode([MailServerNotice].self, from: Data(row.payloadJSON.utf8))
            else { continue }
            reported.insert(row.loginId)
            for notice in notices {
                let key = "\(row.loginId):\(notice.id)"
                present.insert(key)
                guard !shown.contains(key) else { continue }
                shown.insert(key)
                await center.add(Self.request(for: notice, loginId: row.loginId))
            }
        }
        shown = shown.filter { key in
            guard let login = key.split(separator: ":").first.flatMap({ Int64($0) }) else { return false }
            return !reported.contains(login) || present.contains(key)
        }
        defaults.set(shown.sorted(), forKey: Self.shownNoticesKey)
    }

    nonisolated static func request(for notice: MailServerNotice, loginId: Int64) -> MailNotificationRequest {
        MailNotificationRequest(
            identifier: "nextcloud-\(loginId)-\(notice.id)",
            title: notice.subject,
            body: notice.message ?? "",
            threadIdentifier: "nextcloud-\(loginId)",
            category: .server,
            link: notice.link.flatMap(URL.init(string:))
        )
    }

    // MARK: - Responses

    func handle(_ response: MailNotificationResponse) async {
        switch response.action {
        case .archive, .markRead:
            guard let messageId = response.messageId else { return }
            await triage(response.action, messageId: messageId)
        case .reply:
            activateApp()
            guard let messageId = response.messageId else { return }
            guard let openComposer else { return pending.append(response) }
            openComposer(.reply(messageId: messageId, mode: .sender))
        case .open:
            activateApp()
            if let link = response.link {
                openURL(link)
            } else if let messageId = response.messageId {
                guard let openMessage else { return pending.append(response) }
                openMessage(messageId)
            } else if let mailboxId = response.mailboxId {
                navigation?.select(.mailbox(mailboxId))
            }
        }
    }

    /// Queued exactly as the toolbar queues it, so it applies to the mirror at once and is
    /// sent whenever the account's drainer next can.
    private func triage(_ action: MailNotificationResponse.Action, messageId: Int64) async {
        do {
            guard let message = try await store.message(id: messageId) else { return }
            let accountId = message.accountId
            let queue = queue(accountId)
            switch action {
            case .archive:
                guard let archive = try await queue.localMailboxId(for: .archive, accountId: accountId) else { return }
                guard archive != message.mailboxId else { return }
                try await queue.perform(
                    .move(messageIds: [messageId], destinationMailboxId: archive), accountId: accountId)
            case .markRead:
                guard !message.isSeen else { return }
                try await queue.perform(.setFlags(messageIds: [messageId], flags: ["seen": true]), accountId: accountId)
            case .open, .reply:
                return
            }
            center.removeDelivered(identifiers: ["message-\(messageId)"])
        } catch {
            Self.logger.error("notification action not queued: \(String(describing: error), privacy: .public)")
        }
    }

    private func flushPending() {
        guard openComposer != nil, openMessage != nil, !pending.isEmpty else { return }
        let waiting = pending
        pending.removeAll()
        Task {
            for response in waiting { await handle(response) }
        }
    }
}
