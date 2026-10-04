// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The Privacy tab: data collection, and the senders whose images always show.
struct PrivacySettingsView: View {
    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        Form {
            SettingsErrorCard(model: model)
            Section {
                PreferenceToggle(
                    title: String(localized: "Data collection"),
                    key: AppPreferences.collectDataKey,
                    isOn: model.preferences.collectData)
            } footer: {
                Text("Allow the app to collect and process data locally to adapt to your preferences")
            }

            Section {
                SettingsLoginPicker(model: model)
                if model.trustedSenders.isEmpty {
                    Text("No senders are trusted at the moment.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.trustedSenders, id: \.email) { sender in
                    HStack {
                        (sender.type == "domain" ? MailSymbol.domain : MailSymbol.account)
                            .view(size: .small)
                        Text(sender.email)
                        Spacer()
                        SettingsIconButton(
                            symbol: .remove, label: String(format: String(localized: "Remove %@"), sender.email)
                        ) { Task { await model.removeTrustedSender(sender) } }
                    }
                }
            } header: {
                Text("Always show images from")
            }
        }
        .formStyle(.grouped)
    }
}
