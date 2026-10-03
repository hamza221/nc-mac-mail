// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailNet
import NextcloudUI
import SwiftUI

/// The sign-in screen: the app's icon, a server field, Continue, the waiting state with
/// Cancel, and the three distinguishable failures
/// [S-01](../../../docs/product/user-stories.md#s-01-sign-in-ws-01) asks for.
///
/// `RootSplitView` shows this until an account exists, and again as the sheet that answers
/// the 401 modal.
struct LoginView: View {
    @Environment(\.ncTheme) private var theme
    @State private var model = LoginViewModel()

    /// Handed the stored credentials once sign-in and the Keychain write
    /// both succeed. The caller decides what "signed in" means for the rest
    /// of the app — out of scope for WS-01 per the brief.
    var onSignedIn: (Credentials) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.comfortable) {
            // The compiled app icon rather than a second copy of the artwork, so the Dock
            // and the first screen can never disagree.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: theme.metrics.avatar.extraLarge, height: theme.metrics.avatar.extraLarge)
                .accessibilityHidden(true)

            Text("Sign in to Nextcloud")
                .font(.title2.weight(theme.typography.heading))

            switch model.phase {
            case .enteringServer:
                serverForm
            case .waitingForBrowser:
                waitingForBrowser
            case .failed(let failure):
                serverForm
                NCNoteCard(.error, title: failure.title, message: failure.message)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: 360)
        .onAppear { model.onSignedIn = onSignedIn }
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            TextField("cloud.example.com", text: $model.serverText)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .disableAutocorrection(true)
                .onSubmit { model.continueTapped() }
                .ncAccessibilityLabel(.text("Nextcloud server address"))

            Button("Continue") { model.continueTapped() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.serverText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var waitingForBrowser: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            ProgressView()
                .progressViewStyle(.normal)
                .ncAccessibilityLabel(.text("Waiting for the browser"))

            Text("Waiting for the browser…")

            Button("Cancel") { model.cancelTapped() }
                .buttonStyle(.tertiary)
                .keyboardShortcut(.cancelAction)
        }
    }
}

#Preview {
    LoginView()
        .ncTheme(.nextcloud)
}
