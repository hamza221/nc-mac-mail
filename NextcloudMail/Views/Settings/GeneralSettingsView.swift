// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The General tab: the two reading preferences the brief asks for, plus a line about
/// appearance that has nothing to configure.
struct GeneralSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore

    @State private var markAsReadDelay = MarkAsReadDelay.immediately
    @State private var hasLoadedMarkAsReadDelay = false

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Message list"), selection: listViewBinding) {
                    Text("Threaded").tag(ListView.threaded)
                    Text("Flat").tag(ListView.flat)
                }
                .accessibilityHint(Text("Whether the message list groups replies into one row per thread."))

                Picker(String(localized: "Mark as read"), selection: markAsReadBinding) {
                    ForEach(MarkAsReadDelay.offeredDelays, id: \.self) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .accessibilityHint(Text("When an opened message is marked read."))
            } header: {
                Text("Reading")
            }

            Section {
                NCNoteCard(.info) {
                    Text("Appearance follows the system's Light, Dark or Auto setting.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadMarkAsReadDelay() }
    }

    private var listViewBinding: Binding<ListView> {
        Binding(
            get: { session.navigation.listView },
            set: { session.navigation.setListView($0) }
        )
    }

    private var markAsReadBinding: Binding<MarkAsReadDelay> {
        Binding(
            get: { markAsReadDelay },
            set: { newValue in
                markAsReadDelay = newValue
                Task { await settingsStore.setMarkAsReadDelay(newValue) }
            }
        )
    }

    private func loadMarkAsReadDelay() async {
        guard !hasLoadedMarkAsReadDelay else { return }
        hasLoadedMarkAsReadDelay = true
        markAsReadDelay = await settingsStore.markAsReadDelay()
    }
}
