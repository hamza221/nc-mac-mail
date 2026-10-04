// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import OSLog
import SwiftUI

/// "Add mail account" for one signed-in login: the entry point Settings (WS-38) places, which
/// presents ``AccountSetupSheet``. Hidden while the login's `allowNewAccounts` is `false`;
/// nil — not yet discovered — counts as allowed (server-flags.md).
///
/// Hidden, it is a zero-size view rather than nothing, so the flag stays observed and the
/// button comes back if the admin re-allows new accounts.
struct AddMailAccountButton: View {
    /// The login's `AccountSession.id`.
    let sessionId: String

    @Environment(AppSession.self) private var session
    @State private var allowsNewAccounts: Bool?
    @State private var isPresenting = false

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "accountSetup")

    var body: some View {
        content
            .task(id: sessionId) { await observe() }
            .sheet(isPresented: $isPresenting) {
                AccountSetupSheet(sessionId: sessionId) { _ in isPresenting = false }
            }
    }

    @ViewBuilder
    private var content: some View {
        if allowsNewAccounts == false {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        } else {
            Button(String(localized: "Add mail account")) { isPresenting = true }
        }
    }

    private func observe() async {
        guard let identity = session.accounts.first(where: { $0.id == sessionId })?.identity else { return }
        do {
            for try await login in session.store.observeLogin(for: identity) {
                allowsNewAccounts = login?.allowNewAccounts
            }
        } catch {
            Self.logger.error("login observation ended")
        }
    }
}
