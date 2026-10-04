// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// One row of the Accounts tab's sidebar: a settings page of one account.
struct AccountSettingsTarget: Hashable {
    let accountId: Int64
    let group: AccountSettingsGroup
}

/// The Accounts tab: a sidebar listing every mirrored account with its settings pages
/// (``AccountSettingsGroup``) under it and "Add mail account" at its foot; on the right the
/// selected account's header (name, address, sync status, Open Web Client, Sign Out) above
/// the selected page, and the two-question sign-out flow
/// [offline-queue.md](../../../docs/architecture/offline-queue.md#sign-out-and-pending-work)
/// asks for.
struct AccountsSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var queuePrompt: QueuePrompt?
    @State private var keepOrRemovePrompt: KeepOrRemovePrompt?
    /// The account whose settings show on the right. Bound to the key the sidebar's
    /// "Account settings…" writes, so a request lands even with the window already open.
    @AppStorage(SettingsTab.preferredAccountIDKey) private var preferredAccountID: Int?
    /// The page asked for; an account without it shows General instead
    /// (``AccountSettingsGroup/resolved(for:)``), and switching accounts keeps it.
    @State private var group = AccountSettingsGroup.general

    private var selectedAccount: AccountRecord? {
        settingsStore.accounts.first { Int($0.id) == preferredAccountID } ?? settingsStore.accounts.first
    }

    private var selection: Binding<AccountSettingsTarget?> {
        Binding(
            get: {
                selectedAccount.map { AccountSettingsTarget(accountId: $0.id, group: group.resolved(for: $0)) }
            },
            set: { target in
                guard let target else { return }
                preferredAccountID = Int(target.accountId)
                group = target.group
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            if settingsStore.accounts.isEmpty {
                Text("No accounts are mirrored yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(settingsStore.accounts) { account in
                Section {
                    ForEach(AccountSettingsGroup.visible(for: account)) { group in
                        NCNavigationItem(group.title)
                            .tag(AccountSettingsTarget(accountId: account.id, group: group))
                    }
                } header: {
                    NCNavigationCaption(account.emailAddress)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            addAccountBar
        }
    }

    /// WS-40's "Add mail account", once per login; captioned with the login when there are
    /// several, so the user knows which server the new account lands on.
    private var addAccountBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                ForEach(session.accounts) { login in
                    VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                        if session.accounts.count > 1 {
                            Text(
                                String(
                                    format: String(localized: "%@ on %@"), login.loginName, login.server.host() ?? "")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        AddMailAccountButton(sessionId: login.id)
                    }
                }
            }
            .padding(theme.metrics.spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let account = selectedAccount {
            VStack(spacing: 0) {
                header(for: account)
                Divider()
                AccountSettingsView(
                    accountId: account.id,
                    group: Binding(get: { group.resolved(for: account) }, set: { group = $0 })
                )
                .id(account.id)
            }
        } else {
            ContentUnavailableView { Text("No accounts are mirrored yet.") }
        }
    }

    private func header(for account: AccountRecord) -> some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            NCAvatar(displayName: account.name, size: .medium, label: .decorative)
            VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                Text(account.name)
                    .font(.headline)
                Text(account.emailAddress)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(statusLine(for: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: theme.metrics.spacing.standard)
            Button(String(localized: "Open Web Client")) { openWebClient(for: account) }
            Button(String(localized: "Sign Out"), role: .destructive) { beginSignOut(account) }
        }
        .padding(.horizontal, theme.metrics.spacing.comfortable)
        .padding(.vertical, theme.metrics.spacing.standard)
        .accessibilityElement(children: .contain)
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
