// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailNet
import NextcloudUI
import SwiftUI

/// `LoginView` before there is an account, three columns after.
///
/// The columns are still WS-07/WS-08/WS-09's placeholders — this workstream owns the shell
/// around them: the split view itself, its column-width restoration, the status footer, the
/// sign-in gate, and the one 401 modal. Window size and the selected mailbox restore too, per
/// [ux-spec.md](../../docs/product/ux-spec.md#window), but the second half of that has
/// nothing to restore yet: see `AppSession.needsSignIn` and `NavigationState` for what exists
/// today versus what WS-07/WS-08 wire in once the columns have real content.
struct RootSplitView: View {
    @Environment(AppSession.self) private var session

    @SceneStorage("shell.sidebarWidth") private var sidebarWidth = ColumnWidth.sidebar.ideal
    @SceneStorage("shell.contentWidth") private var contentWidth = ColumnWidth.content.ideal

    @State private var isShowingExpiredAlert = false
    @State private var isPresentingReauth = false

    var body: some View {
        if session.needsSignIn {
            LoginView(onSignedIn: session.signedIn)
        } else {
            NavigationSplitView {
                PlaceholderColumn(title: "Mailboxes")
                    .navigationSplitViewColumnWidth(
                        min: ColumnWidth.sidebar.min, ideal: sidebarWidth, max: ColumnWidth.sidebar.max
                    )
                    .trackingWidth($sidebarWidth)
                    .safeAreaInset(edge: .bottom) { StatusFooter(status: session.status) }
            } content: {
                PlaceholderColumn(title: "Messages")
                    .navigationSplitViewColumnWidth(
                        min: ColumnWidth.content.min, ideal: contentWidth, max: ColumnWidth.content.max
                    )
                    .trackingWidth($contentWidth)
            } detail: {
                PlaceholderColumn(title: "Message")
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

private struct PlaceholderColumn: View {
    @Environment(\.ncTheme) private var theme

    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(theme.colors.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
