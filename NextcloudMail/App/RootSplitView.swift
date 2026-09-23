// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

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

    @SceneStorage("shell.sidebarWidth") private var sidebarWidth = ColumnWidth.sidebar.ideal
    @SceneStorage("shell.contentWidth") private var contentWidth = ColumnWidth.content.ideal

    @State private var isShowingExpiredAlert = false
    @State private var isPresentingReauth = false

    init(session: AppSession) {
        self.session = session
        _sidebar = State(initialValue: SidebarStore(store: session.store))
        _messageList = State(initialValue: MessageListStore(store: session.store))
    }

    var body: some View {
        if session.needsSignIn {
            LoginView(onSignedIn: session.signedIn)
        } else {
            NavigationSplitView {
                SidebarView(model: sidebar, navigation: session.navigation)
                    .navigationSplitViewColumnWidth(
                        min: ColumnWidth.sidebar.min, ideal: sidebarWidth, max: ColumnWidth.sidebar.max
                    )
                    .trackingWidth($sidebarWidth)
                    .safeAreaInset(edge: .bottom) { StatusFooter(status: session.status) }
            } content: {
                SearchableMessageList(
                    model: session.search,
                    list: messageList,
                    navigation: session.navigation,
                    isOffline: session.status.isOffline
                )
                .navigationSplitViewColumnWidth(
                    min: ColumnWidth.content.min, ideal: contentWidth, max: ColumnWidth.content.max
                )
                .trackingWidth($contentWidth)
                .task { session.triage.listStore = messageList }
            } detail: {
                detailColumn
                    .navigationSplitViewColumnWidth(min: ColumnWidth.detail.min, ideal: ColumnWidth.detail.ideal)
            }
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

    /// The message, from the account the selected mailbox belongs to.
    ///
    /// `.id(accountId)` is what makes a second account correct rather than nearly correct:
    /// `MessageView` builds its model from `services` once, in `init`, so switching to a
    /// mailbox on another server has to rebuild the view or the WebView would go on fetching
    /// assets with the first account's client.
    @ViewBuilder
    private var detailColumn: some View {
        let accountId = messageList.mailbox?.accountId
        if let services = session.messageServices(accountId: accountId) {
            MessageView(
                services: services,
                messageId: messageList.focusedMessageId,
                isOffline: session.status.isOffline,
                select: { messageList.selection = [$0] }
            )
            .id(accountId)
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
            Text("\(count) action\(count == 1 ? "" : "s") waiting")
                .font(.caption)
                .padding(theme.metrics.spacing.tight)
        case .none:
            EmptyView()
        }
    }
}
