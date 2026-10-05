// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The Appearance tab: the web's §2.4 controls over the preferences WS-29's list already
/// reads (``MessageListPreferenceStore``), plus the local Threaded/Flat grouping.
struct AppearanceSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        let list = model.listPreferences.preferences
        Form {
            SettingsErrorCard(model: model)
            Section {
                Toggle(
                    String(localized: "Show all messages in thread"),
                    isOn: Binding(
                        get: { model.preferences.showAllMessagesInThread },
                        set: { value in
                            Task {
                                await model.setPreference(
                                    AppPreferences.layoutMessageViewKey, value ? "threaded" : "singleton")
                            }
                        })
                )
                PreferenceToggle(
                    title: String(localized: "Sort favorites up"),
                    key: MessageListPreferences.favoritesKey,
                    isOn: list.favoritesOnTop)
                Picker(
                    String(localized: "Layout"),
                    selection: binding(list.layout, MessageListPreferences.layoutKey, \.rawValue)
                ) {
                    ForEach(MessageListLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                PreferenceToggle(
                    title: String(localized: "Use compact mode"),
                    key: MessageListPreferences.compactKey,
                    isOn: list.isCompact)
                Picker(
                    String(localized: "Sorting"),
                    selection: binding(list.sortOrder, MessageListPreferences.sortOrderKey, \.rawValue)
                ) {
                    Text("Newest first").tag(MessageSortOrder.newest)
                    Text("Oldest first").tag(MessageSortOrder.oldest)
                }
            } header: {
                Text("Message list")
            }

            Section {
                Picker(String(localized: "Group messages"), selection: listViewBinding) {
                    Text("Threaded").tag(ListView.threaded)
                    Text("Flat").tag(ListView.flat)
                }
                .accessibilityHint(Text("Whether the message list groups replies into one row per thread."))
            } footer: {
                Text("Kept on this Mac only.")
            }

            Section {
                NCNoteCard(.info) {
                    Text("Appearance follows the system's Light, Dark or Auto setting.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value: Hashable>(
        _ value: Value, _ key: String, _ raw: @escaping (Value) -> String
    ) -> Binding<Value> {
        Binding(get: { value }, set: { newValue in Task { await model.setPreference(key, raw(newValue)) } })
    }

    private var listViewBinding: Binding<ListView> {
        Binding(
            get: { session.navigation.listView },
            set: { session.navigation.setListView($0) }
        )
    }
}
