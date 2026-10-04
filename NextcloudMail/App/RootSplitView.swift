// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailNet
import NextcloudUI
import SwiftUI

/// `LoginView` before there is an account, three columns after.
///
/// The shell owns the split view, the column-width restoration, the status footer, the
/// sign-in gate and the one 401 modal. The contents of the three columns belong to WS-07,
/// WS-08 and WS-09; what is here is the construction of their models, which all three need a
/// `MailStore` for and none of them may open one themselves.
///
/// `session` is passed in rather than read from the environment because the two column models
/// are `@State` built in `init`, so they survive a redraw instead of being rebuilt — and the
/// store they take is not available to a `@State` initialiser through `@Environment`.
struct RootSplitView: View {
    private let session: AppSession

    @State private var sidebar: SidebarStore
    @State private var messageList: MessageListStore
    @State private var listPreferences: MessageListPreferenceStore
    /// The Contacts section's shared state: per-login models and the list selection (WS-35).
    @State private var contacts: ContactsBrowser

    @SceneStorage("shell.sidebarWidth") private var sidebarWidth = ColumnWidth.sidebar.ideal
    @SceneStorage("shell.contentWidth") private var contentWidth = ColumnWidth.content.ideal

    @State private var isShowingExpiredAlert = false
    @State private var isPresentingReauth = false
    @State private var isShowingMirrorAlert = false

    init(session: AppSession) {
        self.session = session
        let sidebar = SidebarStore(store: session.store)
        // The sidebar's own Refresh, which was log-only until the engine existed to call.
        sidebar.refresh = { [weak session] accountId, mailboxId in
            session?.engine.refresh(mailboxId: mailboxId, accountId: accountId)
        }
        _sidebar = State(initialValue: sidebar)
        _messageList = State(initialValue: MessageListWiring.makeStore(session: session))
        _listPreferences = State(initialValue: MessageListWiring.makePreferences(session: session))
        _contacts = State(
            initialValue: ContactsBrowser(
                store: session.store, queue: { [weak session] in session?.engine.contactsQueue(sessionId: $0) }))
    }

    var body: some View {
        shell
            .triagePresentations(session.triage)
            // On the sign-in screen as well as the columns: the mirror is shared by every
            // account, and an unreadable one affects whichever screen comes up first.
            .onAppear { isShowingMirrorAlert = session.mirrorIsTemporary }
            .alert("Your mail on this Mac could not be opened", isPresented: $isShowingMirrorAlert) {
                Button("Delete and Download Again", role: .destructive) { session.deleteMirrorAndRelaunch() }
                Button("Continue Without Saving", role: .cancel) {}
                Button("Quit") { NSApp.terminate(nil) }
            } message: {
                Text(
                    """
                    Nextcloud Mail keeps a copy of your mail on this Mac, and that copy is damaged. \
                    Your mail is safe on the server. Delete the copy and the app downloads it again. \
                    If you continue without saving, nothing you read is kept after you quit.
                    """
                )
            }
    }

    @ViewBuilder
    private var shell: some View {
        if session.needsSignIn {
            LoginView(onSignedIn: session.signedIn)
        } else {
            // The server's `layout-mode` picks the window's shape; the three columns' views
            // are the same in every shape, and the selection lives in `messageList` (WS-29).
            MessageListLayoutHost(
                layout: listPreferences.preferences.layout,
                openedMessageId: $messageList.openedMessageId
            ) {
                SidebarView(model: sidebar, navigation: session.navigation)
                    .navigationSplitViewColumnWidth(
                        min: ColumnWidth.sidebar.min, ideal: sidebarWidth, max: ColumnWidth.sidebar.max
                    )
                    .trackingWidth($sidebarWidth)
                    .safeAreaInset(edge: .bottom) {
                        StatusFooter(status: session.status, retry: { session.engine.retryFailedActions() })
                    }
            } content: {
                contentColumn
                    .navigationSplitViewColumnWidth(
                        min: ColumnWidth.content.min, ideal: contentWidth, max: ColumnWidth.content.max
                    )
                    .trackingWidth($contentWidth)
                    .task { session.triage.listStore = messageList }
            } detail: {
                detailColumn
                    .navigationSplitViewColumnWidth(min: ColumnWidth.detail.min, ideal: ColumnWidth.detail.ideal)
                    // Archive, Delete, Junk, Move, Star, Mark unread, Refresh: the message
                    // pane's toolbar (ux-spec.md#message-view). Built since WS-10 and never
                    // installed, which is why there was no Refresh button.
                    .toolbar { if showsMailbox { TriageToolbar(context: session.triage) } }
                    // Which actions the selection can take is a database read per account.
                    .task(id: messageList.selection) { await session.triage.refreshAvailability() }
            }
            .environment(listPreferences)
            .environment(contacts)
            .task { listPreferences.start() }
            .undoSendBanner(session: session)
            .onChange(of: session.expiredAccount) { _, newValue in
                isShowingExpiredAlert = newValue != nil
            }
            .alert("Your session has expired.", isPresented: $isShowingExpiredAlert) {
                Button("Sign In Again") { isPresentingReauth = true }
            } message: {
                Text("Sign in again.")
            }
            .sheet(isPresented: $isPresentingReauth) {
                LoginView(onSignedIn: { credentials in
                    session.signedIn(credentials)
                    isPresentingReauth = false
                })
            }
        }
    }

    /// Routes on ``SidebarSelection``: every message source is the searchable list (WS-29),
    /// the outbox is WS-27's view, a Contacts entry is WS-35's list
    /// (ux-spec.md, "What the sidebar can select").
    @ViewBuilder
    private var contentColumn: some View {
        switch session.navigation.selection {
        case nil, .mailbox, .unifiedInbox, .priorityInbox, .favorites:
            SearchableMessageList(
                model: session.search,
                list: messageList,
                navigation: session.navigation,
                isOffline: session.status.isOffline,
                triage: session.triage
            )
        case .outbox:
            OutboxView(session: session)
        case .contacts(let sessionId, let scope):
            ContactsListView(sessionId: sessionId, scope: scope)
        }
    }

    /// Nothing selected yet, or a message list: the message detail column.
    private var showsMailbox: Bool {
        session.navigation.selection.map { MessageListSource($0) != nil } ?? true
    }

    /// The message, from the account the selected mailbox belongs to.
    ///
    /// `.id(accountId)` is what makes a second account correct rather than nearly correct:
    /// `MessageView` builds its model from `services` once, in `init`, so switching to a
    /// mailbox on another server has to rebuild the view or the WebView would go on fetching
    /// assets with the first account's client.
    @ViewBuilder
    private var detailColumn: some View {
        let accountId = messageList.focusedAccountId
        if case .contacts(let sessionId, let scope) = session.navigation.selection {
            ContactsDetailColumn(sessionId: sessionId, scope: scope)
        } else if showsMailbox, let services = session.messageServices(accountId: accountId) {
            MessageView(
                services: services,
                messageId: messageList.focusedMessageId,
                isOffline: session.status.isOffline,
                printer: session.printer
            )
            .id(accountId)
            .task(id: messageList.focusedMessageId) {
                guard let opened = messageList.focusedMessageId else { return }
                await session.triage.actions.messageOpened(opened)
            }
        }
    }
}

/// The window column breakpoints [ux-spec.md](../../docs/product/ux-spec.md#window)
/// specifies. Not theme metrics: these are the window's shape, not a spacing or radius
/// token, and `NCTheme` has no slot for them.
///
/// `ideal` is a first-layout hint, not a live binding — SwiftUI's
/// `navigationSplitViewColumnWidth(min:ideal:max:)` has no overload that reports back what a
/// drag resized a column to — which is why `.trackingWidth(_:)` reads the column's rendered
/// width back into the same `@SceneStorage` value instead. See this workstream's report for
/// the caveats of measuring rather than being told.
private enum ColumnWidth {
    static let sidebar = (min: 200.0, ideal: 240.0, max: 320.0)
    static let content = (min: 280.0, ideal: 320.0, max: 480.0)
    static let detail = (min: 420.0, ideal: 420.0)
}

extension View {
    /// Feeds a column's actual rendered width back into `width`, so the value a drag settles
    /// on becomes next launch's `ideal`. An approximation, not a real API for this: it
    /// reflects whatever the column measures at, including its very first layout at `ideal`
    /// itself, which is harmless — that write is a no-op the first time and only changes
    /// `width` when a resize actually moves it.
    fileprivate func trackingWidth(_ width: Binding<Double>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, newValue in
                        width.wrappedValue = newValue
                    }
            }
        }
    }
}

/// One line, in priority order, or nothing at all — [ux-spec.md](../../docs/product/ux-spec.md#sidebar)
/// is explicit that idle chrome is noise.
private struct StatusFooter: View {
    let status: AppStatus
    /// "Retry now" for actions the server keeps refusing: clears every backoff and drains.
    let retry: () -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        switch status.display {
        case .mirroring(let progress):
            let downloaded = progress.bodiesPresent + progress.bodiesFailed
            HStack(spacing: theme.metrics.spacing.tight) {
                MailSymbol.sync.view(size: .small, label: .decorative)
                Text("Downloading messages — \(downloaded.formatted()) of \(progress.totalMessages.formatted())")
                    .font(.caption)
            }
            .padding(theme.metrics.spacing.tight)
        case .offline:
            Text("Offline")
                .font(.caption)
                .padding(theme.metrics.spacing.tight)
        case .pendingFailures(let count):
            HStack(spacing: theme.metrics.spacing.tight) {
                Text("\(count) action\(count == 1 ? "" : "s") waiting")
                    .font(.caption)
                // The one recovery the spec allows for a queue that keeps failing: an
                // aggregate indicator with a way to try again, never a dialogue.
                Button("Retry", action: retry)
                    .buttonStyle(.tertiary)
                    .controlSize(.small)
            }
            .padding(theme.metrics.spacing.tight)
        case .none:
            EmptyView()
        }
    }
}
