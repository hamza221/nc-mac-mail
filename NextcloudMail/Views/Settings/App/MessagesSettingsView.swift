// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The Messages tab: the web's reading and replying switches, then the text blocks manager.
struct MessagesSettingsView: View {
    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        Form {
            SettingsErrorCard(model: model)
            Section {
                PreferenceToggle(
                    title: String(localized: "Avatars from Gravatar and favicons"),
                    key: AppPreferences.externalAvatarsKey,
                    isOn: model.preferences.externalAvatars)
                PreferenceToggle(
                    title: String(localized: "Search the body of messages in priority Inbox"),
                    key: AppPreferences.searchPriorityBodyKey,
                    isOn: model.preferences.searchPriorityBody)
                Picker(String(localized: "Mark messages as read"), selection: autoMarkBinding) {
                    ForEach(AutoMarkAsRead.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Picker(String(localized: "Reply position"), selection: replyBinding) {
                    Text("Top").tag(false)
                    Text("Bottom").tag(true)
                }
            } header: {
                Text("Reading and replying")
            }

            TextBlocksSection()
        }
        .formStyle(.grouped)
    }

    private var autoMarkBinding: Binding<AutoMarkAsRead> {
        Binding(
            get: { model.preferences.autoMarkAsRead },
            set: { value in Task { await model.setAutoMarkAsRead(value) } })
    }

    private var replyBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.replyAtBottom },
            set: { bottom in Task { await model.setPreference(AppPreferences.replyModeKey, bottom ? "bottom" : "top") }
            })
    }
}
