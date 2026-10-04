// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

extension View {
    /// Applied once, to the main window's root view: hands ``MailNotifier`` the two things
    /// only a SwiftUI scene has — `openComposer` and `openWindow` for a banner's Reply and
    /// click — and the window itself, for the "main window is key" suppression.
    func mailNotifications(_ notifier: MailNotifier) -> some View {
        modifier(MailNotifierHooks(notifier: notifier))
    }
}

struct MailNotifierHooks: ViewModifier {
    let notifier: MailNotifier
    @Environment(\.openComposer) private var openComposer
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background(HostWindowReader { notifier.register(mainWindow: $0) })
            .onAppear {
                let composer = openComposer
                let window = openWindow
                notifier.openComposer = { composer($0) }
                notifier.openMessage = { window(id: MessageWindowScene.id, value: $0) }
            }
    }
}

/// Reports the `NSWindow` its view lands in.
private struct HostWindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        var found: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found?(window) }
        }
    }
}
