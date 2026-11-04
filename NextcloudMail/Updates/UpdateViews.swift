// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// "Check for Updates…" under the app menu's About item, where every Sparkle app puts it.
struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }
}

/// A view inside the command group, as in Sparkle's own SwiftUI example, so the item's
/// enabled state follows `canCheckForUpdates` instead of being read once.
private struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

/// The sidebar line for an update a scheduled check found while the app was in the
/// background. Clicking it opens Sparkle's window for that update.
struct UpdateAvailableBanner: View {
    let updater: AppUpdater

    @Environment(\.ncTheme) private var theme

    var body: some View {
        if let version = updater.pendingUpdateVersion {
            HStack(spacing: theme.metrics.spacing.tight) {
                MailSymbol.info.view(size: .small, label: .decorative)
                Text("Version \(version) is available")
                    .font(.caption)
                Spacer(minLength: 0)
                Button("Update…", action: updater.checkForUpdates)
                    .buttonStyle(.tertiary)
                    .controlSize(.small)
            }
            .padding(theme.metrics.spacing.tight)
        }
    }
}

/// The Updates section of the General settings tab.
struct UpdateSettingsSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section {
            Picker(String(localized: "Channel"), selection: $updater.channel) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            Toggle(String(localized: "Check for updates automatically"), isOn: $updater.automaticallyChecksForUpdates)
            Toggle(
                String(localized: "Download and install automatically"), isOn: $updater.automaticallyDownloadsUpdates
            )
            .disabled(!updater.automaticallyChecksForUpdates)
            LabeledContent(String(localized: "Last checked")) {
                HStack {
                    if let date = updater.lastCheckDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("The beta channel also offers pre-releases, which may be less stable.")
        }
    }
}
