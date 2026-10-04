// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// "Open in New Window": one message, alone, in its own window.
///
/// A `WindowGroup` keyed by the local message id, so opening the same message twice brings
/// its window forward instead of opening a second, and the window restores across a relaunch
/// like the main one. The message view inside is the same `MessageView` the detail column
/// draws, reading the same mirror; nothing here can reach the network either.
struct MessageWindowScene: Scene {
    static let id = "message"

    let session: AppSession

    var body: some Scene {
        WindowGroup(String(localized: "Message"), id: Self.id, for: Int64.self) { $messageId in
            MessageWindow(session: session, messageId: messageId)
                .environment(session)
                .ncTheme(session.theme)
        }
        .defaultSize(width: 720, height: 640)
    }
}

/// The window's content: the message, once its account is known.
///
/// The account decides which server's services the view is built with (the detail column's
/// `.id(accountId)` reasoning), and it is one read of the message row.
private struct MessageWindow: View {
    let session: AppSession
    let messageId: Int64?

    @State private var accountId: Int64?
    @State private var subject: String?

    var body: some View {
        Group {
            if let messageId, let accountId, let services = session.messageServices(accountId: accountId) {
                MessageView(
                    services: services,
                    messageId: messageId,
                    isOffline: session.status.isOffline
                )
                .id(accountId)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No message")
                    } icon: {
                        MailSymbol.inbox.view(size: .large, label: .decorative)
                    }
                }
            }
        }
        .navigationTitle(subject ?? String(localized: "Message"))
        .task(id: messageId) {
            guard let messageId, let message = try? await session.store.message(id: messageId) else {
                accountId = nil
                return
            }
            accountId = message.accountId
            subject = message.subject
        }
    }
}
