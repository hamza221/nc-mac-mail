// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The Storage tab: the panel [ADR-0008](../../../docs/decisions/0008-no-automatic-eviction.md)
/// promises. The mirror never evicts anything on its own; this is where the user does it
/// on purpose, and where the cost of not evicting is made visible instead of hidden.
struct StorageSettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.ncTheme) private var theme

    @State private var removePrompt: AccountPrompt?
    @State private var reDownloadPrompt: AccountPrompt?

    var body: some View {
        Form {
            if settingsStore.accounts.isEmpty {
                Section {
                    Text("No accounts are mirrored yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(settingsStore.accounts) { account in
                    Section {
                        accountBody(account)
                    } header: {
                        Text(verbatim: "\(account.name) \u{00B7} \(account.emailAddress)")
                    }
                }
            }

            Section {
                Text(String(format: String(localized: "Mirror database on disk: %@"), diskSizeText))
                    .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "One database holds every account, so this total cannot be split between them. "
                        + "The message counts and sizes above are each account's own bodies and attachments, "
                        + "which is what Remove Local Copies actually frees."
                )
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            String(localized: "Remove Local Copies?"),
            isPresented: Binding(get: { removePrompt != nil }, set: { if !$0 { removePrompt = nil } }),
            presenting: removePrompt
        ) { prompt in
            Button(String(localized: "Remove"), role: .destructive) {
                removePrompt = nil
                Task { await settingsStore.removeLocalCopies(accountId: prompt.account.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { removePrompt = nil }
        } message: { prompt in
            Text(
                "This removes local copies only for \(prompt.account.emailAddress). "
                    + "It does not touch mail on the server. Bodies, inline images and the search "
                    + "index for this account are deleted; the message list stays, and bodies "
                    + "re-fetch when you open them."
            )
        }
        .confirmationDialog(
            String(localized: "Re-download Messages?"),
            isPresented: Binding(get: { reDownloadPrompt != nil }, set: { if !$0 { reDownloadPrompt = nil } }),
            presenting: reDownloadPrompt
        ) { prompt in
            Button(String(localized: "Re-download"), role: .destructive) {
                reDownloadPrompt = nil
                Task { await settingsStore.reDownload(accountId: prompt.account.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { reDownloadPrompt = nil }
        } message: { prompt in
            Text(
                "This removes local copies only for \(prompt.account.emailAddress) and downloads "
                    + "them again from the server. It does not touch mail on the server, and the "
                    + "backfill restarts from zero bodies without touching the message list."
            )
        }
    }

    @ViewBuilder
    private func accountBody(_ account: AccountRecord) -> some View {
        let footprint = settingsStore.footprints[account.id]
        let progress = settingsStore.progresses[account.id]
        let isPaused = settingsStore.pausedAccountIDs.contains(account.id)
        let isBusy = settingsStore.busyAccountIDs.contains(account.id)
        let hasLiveClient = settingsStore.client(for: account) != nil

        VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
            Text(summaryLine(footprint: footprint, account: account))
            Text(SettingsFormatting.mirrorStatus(state: account.mirrorState, progress: progress, isPaused: isPaused))
                .foregroundStyle(.secondary)
        }

        if settingsStore.slowMirrorAccountIDs.contains(account.id) {
            NCNoteCard(.info) {
                Text(
                    "This account's server shows oldest messages first. Mirroring stays correct, "
                        + "but a new reply can take up to a week to appear here instead of a couple "
                        + "of minutes, because the backfill cannot scan from the newest end."
                )
            }
        }

        HStack {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Working"))
            }
            Button(String(localized: "Remove Local Copies")) { removePrompt = AccountPrompt(account: account) }
                .disabled(isBusy)
            Button(String(localized: "Re-download")) { reDownloadPrompt = AccountPrompt(account: account) }
                .disabled(isBusy)
            Button(String(localized: "Check for Missing Messages")) {
                Task { await settingsStore.checkForMissingMessages(accountId: account.id) }
            }
            .disabled(isBusy || !hasLiveClient)
            .help(
                hasLiveClient
                    ? String(localized: "Compares the mirror against the server and adds anything missing.")
                    : String(localized: "This account has no active session this launch.")
            )
            if isPaused {
                Button(String(localized: "Resume")) {
                    Task { await settingsStore.resumeBackfill(accountId: account.id) }
                }
                .disabled(isBusy || !hasLiveClient)
            } else {
                Button(String(localized: "Pause")) {
                    Task { await settingsStore.pauseBackfill(accountId: account.id) }
                }
                .disabled(isBusy)
            }
        }
    }

    private func summaryLine(footprint: StorageFootprint?, account: AccountRecord) -> String {
        guard let footprint else {
            return String(localized: "Local size unavailable")
        }
        return String(
            format: String(localized: "%@ messages \u{00B7} %@ local"),
            SettingsFormatting.messageCount(footprint.messageCount),
            SettingsFormatting.bytes(footprint.bodyBytes + footprint.attachmentBytes)
        )
    }

    private var diskSizeText: String { SettingsFormatting.bytes(settingsStore.mirrorFileSizeOnDisk) }
}

/// One account, presented for a confirmation dialog. Shared by Remove Local Copies and
/// Re-download, which each need their own `@State` instance so the two dialogs never fight
/// over which account they are about.
private struct AccountPrompt: Identifiable {
    let account: AccountRecord
    var id: Int64 { account.id }
}
