// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// "Nextcloud account" above a server-scoped list, only when more than one login is signed
/// in (ADR-0091). One login needs no choice.
struct SettingsLoginPicker: View {
    @Bindable var model: AppSettingsModel

    var body: some View {
        if model.logins.count > 1 {
            Picker(String(localized: "Nextcloud account"), selection: selection) {
                ForEach(model.logins, id: \.id) { login in
                    Text(Self.title(login)).tag(login.id)
                }
            }
        }
    }

    private var selection: Binding<Int64?> {
        Binding(get: { model.selectedLogin?.id }, set: { model.selectedLoginId = $0 })
    }

    static func title(_ login: LoginRecord) -> String {
        let host = URL(string: login.serverURL)?.host() ?? login.serverURL
        return String(format: String(localized: "%@ on %@"), login.loginName, host)
    }
}

/// A switch over one boolean preference, read from the mirror and queued for every login.
struct PreferenceToggle: View {
    let title: String
    let key: String
    let isOn: Bool
    var isDisabled = false

    @Environment(AppSettingsModel.self) private var model

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in Task { await model.setBool(key, value) } }))
            .disabled(isDisabled)
    }
}

/// The model's one-shot error, in the web's wording, dismissed with the card's button.
struct SettingsErrorCard: View {
    @Bindable var model: AppSettingsModel

    var body: some View {
        if let message = model.errorMessage {
            NCNoteCard(.error) {
                HStack {
                    Text(message)
                    Spacer()
                    Button(String(localized: "Dismiss")) { model.errorMessage = nil }
                }
            }
        }
    }
}

/// An icon-only row button with its accessibility label, the list rows' remove/edit.
struct SettingsIconButton: View {
    let symbol: MailSymbol
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { symbol.view(size: .small) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(Text(label))
    }
}
