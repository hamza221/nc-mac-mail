// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI

/// The General tab: "Set as default mail app", the mail accounts with a way into each one's
/// settings, and "Add mail account" for every login whose server allows it.
struct GeneralSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AppUpdater.self) private var updater
    @Environment(SettingsStore.self) private var settingsStore

    @AppStorage(SettingsTab.preferredTabKey) private var selectedTab = SettingsTab.general
    @AppStorage(SettingsTab.preferredAccountIDKey) private var preferredAccountID: Int?

    @State private var isDefaultMailApp = false
    @State private var defaultAppError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Mail app")) {
                    Button(DefaultMailAppCheck.label(isDefault: isDefaultMailApp)) {
                        Task { await setAsDefault() }
                    }
                    .disabled(isDefaultMailApp)
                }
                if let defaultAppError {
                    NCNoteCard(.error) { Text(defaultAppError) }
                }
            }

            Section {
                if settingsStore.accounts.isEmpty {
                    Text("No accounts are mirrored yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settingsStore.accounts) { account in
                    Button {
                        preferredAccountID = Int(account.id)
                        selectedTab = .accounts
                    } label: {
                        HStack {
                            Text(Self.accountTitle(account))
                            Spacer()
                            Text("Account settings")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens this account's settings."))
                }
                ForEach(session.accounts) { login in
                    HStack {
                        if session.accounts.count > 1 {
                            Text(
                                String(
                                    format: String(localized: "%@ on %@"), login.loginName, login.server.host() ?? "")
                            )
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        AddMailAccountButton(sessionId: login.id)
                    }
                }
            } header: {
                Text("Account settings")
            }

            UpdateSettingsSection(updater: updater)
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshDefault)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDefault()
        }
    }

    /// `{email}`, or `{email} (delegated)` for an account someone else delegated.
    static func accountTitle(_ account: AccountRecord) -> String {
        account.isDelegated
            ? String(format: String(localized: "%@ (delegated)"), account.emailAddress)
            : account.emailAddress
    }

    private static var liveCheck: DefaultMailAppCheck {
        DefaultMailAppCheck(
            handler: {
                guard let mailto = URL(string: "mailto:") else { return nil }
                return NSWorkspace.shared.urlForApplication(toOpen: mailto)
            },
            bundleURL: Bundle.main.bundleURL)
    }

    private func refreshDefault() {
        isDefaultMailApp = Self.liveCheck.isDefault()
    }

    /// Launch Services asks the user to confirm; declining is an error, shown as such.
    private func setAsDefault() async {
        defaultAppError = nil
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
        } catch {
            defaultAppError = String(localized: "Could not set this app as the default mail app.")
        }
        refreshDefault()
    }
}
