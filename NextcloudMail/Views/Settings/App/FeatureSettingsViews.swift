// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The Assistance tab: follow-up reminders, enabled when a server offers them (ADR-0091).
struct AssistanceSettingsView: View {
    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        Form {
            SettingsErrorCard(model: model)
            Section {
                PreferenceToggle(
                    title: String(localized: "Remind about messages that require a reply but received none"),
                    key: AppPreferences.followUpKey,
                    isOn: model.preferences.followUpReminders,
                    isDisabled: !model.followUpAvailable)
            } footer: {
                if !model.followUpAvailable {
                    Text("Your Nextcloud server does not offer follow-up reminders.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The Context Chat tab: whether this login's mail is indexed for Context Chat.
struct ContextChatSettingsView: View {
    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        Form {
            SettingsErrorCard(model: model)
            Section {
                PreferenceToggle(
                    title: String(localized: "Make mails available to Context Chat"),
                    key: AppPreferences.contextChatKey,
                    isOn: model.preferences.contextChat,
                    isDisabled: !model.contextChatAvailable)
            } footer: {
                if model.contextChatAvailable {
                    Text("Context Chat answers questions using your mail as a source.")
                } else {
                    Text("Your Nextcloud server does not offer Context Chat.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Help ▸ Keyboard Shortcuts, embedded.
struct ShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            KeyboardShortcutsView()
                .frame(maxWidth: .infinity)
        }
    }
}

/// Version and acknowledgements. This build has no CKEditor, so the web's GPLv2 CKEditor
/// line gives way to the libraries the app does ship.
struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Version"), value: Self.version)
            }
            Section {
                Text("Nextcloud Mail for macOS is free software under the GNU AGPL, version 3 or later.")
                Text(
                    "It uses NextcloudUI, Nextcloud's design system for Apple platforms, and GRDB, a SQLite toolkit by Gwendal Roué (MIT License)."
                )
            } header: {
                Text("Acknowledgements")
            }
        }
        .formStyle(.grouped)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
