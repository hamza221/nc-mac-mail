// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog
import SwiftUI
import WidgetKit

/// The app's side of macOS integration (WS-42), started once from the main window:
///
/// - the ``SystemRouter`` every ``SystemLink`` goes through — `mailto:` and `ncmail:` URLs,
///   Spotlight results, widget taps, the Share extension's hand-off, the Services menu;
/// - the store observations that keep Spotlight (``SpotlightIndexer``) and the widget
///   snapshot (``WidgetSnapshotWriter``) equal to the mirror.
///
/// The two hooks in WS-25's shell are one line each: `.systemIntegration(session:)` on the
/// main window and `.systemRouting(messageList:contacts:)` inside it.
@MainActor
final class SystemIntegration {
    static let shared = SystemIntegration()

    private(set) var router: SystemRouter?
    private var feeds: [Task<Void, Never>] = []
    /// How often an observation is acted on at most. Sync writes in bursts; Spotlight and
    /// WidgetKit want the settled result, not every intermediate one.
    static let throttle: Duration = .seconds(1)

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "system")

    func start(
        session: AppSession,
        openComposer: @escaping @MainActor (ComposeRequest) -> Void,
        openMessageWindow: @escaping @MainActor (Int64) -> Void
    ) {
        guard router == nil else { return }
        let router = SystemRouter(
            store: session.store, navigation: session.navigation, openComposer: openComposer,
            openMessageWindow: openMessageWindow)
        self.router = router

        // A Share hand-off whose `ncmail://shared/` link was lost (the app was not running
        // and the open failed) is still in the inbox; the composer window for the same
        // request is the same window, so a link that does arrive opens nothing twice.
        if let inbox = SharedInbox.inboxURL {
            for itemId in SharedInboxDrop.pendingItemIds(inbox: inbox) {
                SystemEvents.shared.post(.shared(inboxItemId: itemId))
            }
        }
        feeds.append(
            Task { [weak session] in
                // `AppSession.start()` restores the saved selection once the accounts are
                // read; a link that arrived with the launch must land after it, not under it.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while let session, session.accounts.isEmpty, !session.needsSignIn, clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(300))
                SystemEvents.shared.setHandler { link in
                    Task { await router.handle(link) }
                }
            })

        let store = session.store
        let spotlight = SpotlightIndexer(index: CoreSpotlightIndex())
        feeds.append(Self.feedSpotlightMessages(store: store, indexer: spotlight))
        feeds.append(Self.feedSpotlightContacts(store: store, indexer: spotlight))
        if let container = AppGroup.containerURL {
            let writer = WidgetSnapshotWriter(
                fileURL: WidgetSnapshot.url(in: container),
                reload: { WidgetCenter.shared.reloadAllTimelines() })
            feeds.append(Self.feedWidgetSnapshot(store: store, writer: writer))
        } else {
            Self.logger.error("no app group container; widgets get no snapshot")
        }
    }

    func attach(messageList: MessageListStore, contacts: ContactsBrowser) {
        router?.messageList = messageList
        router?.contacts = contacts
    }

    // MARK: - Feeds

    /// An observation as a stream that keeps only its newest value, consumed at most once
    /// per ``throttle``.
    nonisolated static func throttled<Element: Sendable>(
        _ observation: StoreObservation<Element>
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch {
                    logger.error("system observation stopped: \(String(describing: error), privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func feedSpotlightMessages(store: MailStore, indexer: SpotlightIndexer) -> Task<Void, Never> {
        Task.detached {
            // An empty mailbox list is every mailbox of every account.
            let observation = store.observeMessages(
                query: MessageListQuery(mailboxIds: []), view: .flat, order: .newest,
                range: 0..<SpotlightIndexer.messageLimit)
            for await rows in throttled(observation) {
                await indexer.updateMessages(rows)
                try? await Task.sleep(for: throttle)
            }
        }
    }

    /// One observation per signed-in login, started and stopped as accounts come and go.
    private static func feedSpotlightContacts(store: MailStore, indexer: SpotlightIndexer) -> Task<Void, Never> {
        Task.detached {
            var perLogin: [Int64: Task<Void, Never>] = [:]
            for await accounts in throttled(store.observeAccounts()) {
                var loginIds: Set<Int64> = []
                for identity in Set(accounts.map { ServerIdentity(serverURL: $0.serverURL, loginName: $0.loginName) }) {
                    if let id = try? await store.login(for: identity)?.id { loginIds.insert(id) }
                }
                for (loginId, task) in perLogin where !loginIds.contains(loginId) {
                    task.cancel()
                    perLogin[loginId] = nil
                    await indexer.removeContacts(loginId: loginId)
                }
                for loginId in loginIds where perLogin[loginId] == nil {
                    perLogin[loginId] = Task {
                        for await records in throttled(store.observeContacts(loginId: loginId)) {
                            await indexer.updateContacts(records, loginId: loginId) { contactId in
                                ((try? await store.contactEmails(contactId: contactId)) ?? []).map(\.email)
                            }
                            try? await Task.sleep(for: throttle)
                        }
                    }
                }
            }
            for task in perLogin.values { task.cancel() }
        }
    }

    /// ADR-0071's two lists: Important across every inbox, and unread across every inbox,
    /// each the newest ``WidgetSnapshot/cap``.
    private static func feedWidgetSnapshot(store: MailStore, writer: WidgetSnapshotWriter) -> Task<Void, Never> {
        Task.detached {
            var current: Task<Void, Never>?
            for await inboxIds in throttled(store.observeInboxMailboxIds()) {
                current?.cancel()
                current = Task {
                    let lists = WidgetInboxLists(writer: writer, inboxIds: inboxIds)
                    // An empty list would mean every mailbox: no inbox is no rows.
                    guard !inboxIds.isEmpty else {
                        await lists.setImportant([])
                        return
                    }
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            let important = store.observeMessages(
                                query: MessageListQuery(mailboxIds: inboxIds, isImportant: true), view: .flat,
                                order: .newest, range: 0..<WidgetSnapshot.cap)
                            for await rows in throttled(important) { await lists.setImportant(rows) }
                        }
                        for inboxId in inboxIds {
                            group.addTask {
                                let unread = store.observeSearchRows(
                                    SearchQuery(
                                        text: "", scope: .mailbox(inboxId),
                                        flags: SearchQuery.FlagFilter(unreadOnly: true)),
                                    range: 0..<WidgetSnapshot.cap)
                                for await rows in throttled(unread) { await lists.setUnread(rows, inboxId: inboxId) }
                            }
                        }
                    }
                }
            }
            current?.cancel()
        }
    }
}

/// The latest value of each inbox observation, so every change rewrites the snapshot from
/// the whole picture rather than from the one list that changed.
private actor WidgetInboxLists {
    private let writer: WidgetSnapshotWriter
    private let inboxIds: [Int64]
    private var important: [MessageRow]?
    private var unread: [Int64: [MessageRow]] = [:]

    init(writer: WidgetSnapshotWriter, inboxIds: [Int64]) {
        self.writer = writer
        self.inboxIds = inboxIds
    }

    func setImportant(_ rows: [MessageRow]) async {
        important = rows
        await flush()
    }

    func setUnread(_ rows: [MessageRow], inboxId: Int64) async {
        unread[inboxId] = rows
        await flush()
    }

    /// Waits until every list has answered once, so the first write is not a half snapshot.
    private func flush() async {
        guard let important, inboxIds.allSatisfy({ unread[$0] != nil }) else { return }
        await writer.update(important: important, unread: unread.values.flatMap { $0 })
    }
}

extension View {
    /// The main window's one hook (WS-42): starts ``SystemIntegration``.
    func systemIntegration(session: AppSession) -> some View {
        modifier(SystemIntegrationModifier(session: session))
    }

    /// Hands the window's list and contacts models to the router, so a link can select a
    /// row in them.
    func systemRouting(messageList: MessageListStore, contacts: ContactsBrowser) -> some View {
        task { SystemIntegration.shared.attach(messageList: messageList, contacts: contacts) }
    }
}

private struct SystemIntegrationModifier: ViewModifier {
    let session: AppSession

    @Environment(\.openComposer) private var openComposer
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let openWindow = openWindow
            SystemIntegration.shared.start(
                session: session,
                openComposer: openComposer.callAsFunction,
                openMessageWindow: { openWindow(id: MessageWindowScene.id, value: $0) }
            )
        }
    }
}
