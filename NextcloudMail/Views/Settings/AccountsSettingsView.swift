// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The Accounts tab: one row per mirrored account, and the two-question sign-out flow
/// [offline-queue.md](../../../docs/architecture/offline-queue.md#sign-out-and-pending-work)
/// asks for.
///
/// Account creation is out of scope
/// ([WS-12-settings.md](../../../docs/delivery/briefs/WS-12-settings.md#out-of-scope)); the
/// footer explains that and opens the web client instead of leaving a blank space.
struct AccountsSettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var queuePrompt: QueuePrompt?
    @State private var keepOrRemovePrompt: KeepOrRemovePrompt?

    var body: some View {
        Form {
            Section {
                if settingsStore.accounts.isEmpty {
                    Text("No accounts are mirrored yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settingsStore.accounts) { account in
                        row(for: account)
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Accounts are added and removed in the Nextcloud web client.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            String(localized: "Some actions have not reached the server yet."),
            isPresented: Binding(get: { queuePrompt != nil }, set: { if !$0 { queuePrompt = nil } }),
            presenting: queuePrompt
        ) { prompt in
            Button(String(localized: "Send Now")) { resolveQueue(prompt, decision: .sendNow) }
            Button(String(localized: "Discard"), role: .destructive) { resolveQueue(prompt, decision: .discard) }
            Button(String(localized: "Cancel"), role: .cancel) { queuePrompt = nil }
        } message: { prompt in
            Text(queueMessage(count: prompt.queuedCount))
        }
        .alert(
            String(localized: "Sign Out"),
            isPresented: Binding(get: { keepOrRemovePrompt != nil }, set: { if !$0 { keepOrRemovePrompt = nil } }),
            presenting: keepOrRemovePrompt
        ) { prompt in
            Button(String(localized: "Keep Local Copies")) { finishSignOut(prompt, removeLocalCopies: false) }
            Button(String(localized: "Remove Local Copies"), role: .destructive) {
                finishSignOut(prompt, removeLocalCopies: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) { keepOrRemovePrompt = nil }
        } message: { prompt in
            Text(
                "Signing out forgets the password for \(prompt.account.emailAddress) on this Mac. "
                    + "This removes local copies only. It does not touch mail on the server. "
                    + "Keep the local copies to leave what is already mirrored in place, or remove "
                    + "them to reclaim the space."
            )
        }
    }

    @ViewBuilder
    private func row(for account: AccountRecord) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                    Text(account.name)
                        .font(.headline)
                    Text(account.emailAddress)
                        .foregroundStyle(.secondary)
                    Text(statusLine(for: account))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Open Web Client")) { openWebClient(for: account) }
                Button(String(localized: "Sign Out"), role: .destructive) { beginSignOut(account) }
            }
        }
        .padding(.vertical, theme.metrics.spacing.tight)
        .accessibilityElement(children: .combine)
    }

    private func statusLine(for account: AccountRecord) -> String {
        let status = SettingsFormatting.mirrorStatus(
            state: account.mirrorState,
            progress: settingsStore.progresses[account.id],
            isPaused: settingsStore.pausedAccountIDs.contains(account.id)
        )
        let lastSync = SettingsFormatting.lastSync(account.lastSyncAt)
        return String(format: String(localized: "%@ · Last synced %@"), status, lastSync)
    }

    private func openWebClient(for account: AccountRecord) {
        guard let server = URL(string: account.serverURL) else { return }
        // Nextcloud Mail's own routes live under `/index.php/apps/mail/`
        // (ADR-0002), which is also the browser-facing path for the app itself.
        openURL(server.appending(path: "index.php/apps/mail/"))
    }

    // MARK: - Sign-out

    private struct QueuePrompt: Identifiable {
        let account: AccountRecord
        let queuedCount: Int
        var id: Int64 { account.id }
    }

    private struct KeepOrRemovePrompt: Identifiable {
        let account: AccountRecord
        var id: Int64 { account.id }
    }

    private func beginSignOut(_ account: AccountRecord) {
        Task {
            let queued = await settingsStore.pendingQueueCount(for: account)
            if queued > 0 {
                queuePrompt = QueuePrompt(account: account, queuedCount: queued)
            } else {
                keepOrRemovePrompt = KeepOrRemovePrompt(account: account)
            }
        }
    }

    private func resolveQueue(_ prompt: QueuePrompt, decision: SettingsStore.QueueDecision) {
        queuePrompt = nil
        Task {
            await settingsStore.resolveQueue(for: prompt.account, decision: decision)
            keepOrRemovePrompt = KeepOrRemovePrompt(account: prompt.account)
        }
    }

    private func finishSignOut(_ prompt: KeepOrRemovePrompt, removeLocalCopies: Bool) {
        keepOrRemovePrompt = nil
        Task { await settingsStore.signOut(account: prompt.account, removeLocalCopies: removeLocalCopies) }
    }

    private func queueMessage(count: Int) -> String {
        let base = String(
            format: String(
                localized: "%d action(s) have not been sent to the server yet. Send them now, or discard them?"
            ),
            count
        )
        let exception = String(
            localized: """
                One case cannot be reverted: deleting a message that was already in Trash also erased it \
                locally, so discarding that one only drops the queued action. The next sync brings the \
                message back from the server, because the server was never told.
                """
        )
        return base + "\n\n" + exception
    }
}
