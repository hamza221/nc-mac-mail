// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The inline line a section shows under its button after a save: the web's toast, kept
/// next to the form it is about.
enum SettingsStatus: Equatable {
    case success(String)
    case failure(String)
}

struct SettingsStatusLine: View {
    let status: SettingsStatus?

    var body: some View {
        switch status {
        case .success(let text):
            NCNoteCard(.success) { Text(text) }
        case .failure(let text):
            NCNoteCard(.error) { Text(text).textSelection(.enabled) }
        case nil:
            EmptyView()
        }
    }
}

/// A button that runs async work and shows a spinner while it does, disabled meanwhile —
/// the web's "spinner on the button" for every command.
struct BusyButton: View {
    let title: String
    var isDisabled = false
    var role: ButtonRole?
    let action: () async -> Void

    @State private var isBusy = false

    var body: some View {
        HStack {
            Button(title, role: role) {
                isBusy = true
                Task {
                    await action()
                    isBusy = false
                }
            }
            .disabled(isDisabled || isBusy)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// What a provisioned account shows instead of a server form (§9): a form section, so it
/// sits in its page's form like the section it replaces.
struct LockedSectionView: View {
    let section: AccountSettingsSection

    var body: some View {
        Section(section.title) {
            NCNoteCard(.info) {
                Text(
                    "This account is managed by your administrator. Its server settings come from the "
                        + "provisioning configuration and cannot be changed here."
                )
            }
        }
    }
}

/// §8.5's hint card, where Autoresponder and Filters would be without Sieve.
struct SieveHintCard: View {
    let goToSieve: () -> Void

    var body: some View {
        NCNoteCard(.info) {
            VStack(alignment: .leading) {
                Text(
                    "Your mail server does not support Sieve or Sieve is not enabled. "
                        + "Autoresponder and filters require it.")
                Button(String(localized: "Go to Sieve settings"), action: goToSieve)
            }
        }
    }
}
