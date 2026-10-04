// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8.4: the autoresponder, read from the Sieve row, saved through `saveOutOfOffice` or
/// `followSystemOutOfOffice` (online only, ADR-0068).
struct AutoresponderSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    let goTo: (AccountSettingsSection) -> Void

    @State private var draft = OutOfOfficeDraft(firstDay: Date())
    @State private var status: SettingsStatus?
    @Environment(\.openURL) private var openURL

    /// The login's `enable-system-out-of-office`; nil is "not discovered yet", which the
    /// flag columns treat as available.
    private var offersSystem: Bool { model.login?.enableSystemOutOfOffice != false }

    var body: some View {
        Form {
            if account.sieveEnabled {
                Section {
                    Text("The autoresponder replies at most once every 4 days per sender.")
                        .foregroundStyle(.secondary)
                    Picker(String(localized: "Autoresponder"), selection: $draft.mode) {
                        ForEach(modes, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    if draft.mode == .followSystem {
                        Button(String(localized: "Edit absence settings")) { openAvailability() }
                    } else {
                        form
                    }
                    BusyButton(title: String(localized: "Save autoresponder"), isDisabled: !draft.canSave) {
                        await save()
                    }
                    SettingsStatusLine(status: status)
                } header: {
                    Text("Autoresponder")
                }
            } else {
                Section("Autoresponder") { SieveHintCard { goTo(.sieveServer) } }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: model.sieve?.outOfOfficeJSON) { _, _ in load() }
    }

    private var modes: [OutOfOfficeDraft.Mode] {
        offersSystem || draft.mode == .followSystem ? OutOfOfficeDraft.Mode.allCases : [.off, .on]
    }

    @ViewBuilder
    private var form: some View {
        let editable = draft.mode == .on
        DatePicker(
            String(localized: "First day"),
            selection: Binding(get: { draft.firstDay }, set: { draft.setFirstDay($0) }),
            displayedComponents: .date
        )
        .disabled(!editable)
        Toggle(
            String(localized: "Last day (optional)"),
            isOn: Binding(get: { draft.hasLastDay }, set: { draft.setHasLastDay($0) })
        )
        .disabled(!editable)
        if let lastDay = draft.lastDay {
            DatePicker(
                String(localized: "Last day"),
                selection: Binding(get: { lastDay }, set: { draft.lastDay = $0 }),
                in: draft.firstDay...,
                displayedComponents: .date
            )
            .disabled(!editable)
        }
        TextField(String(localized: "Subject"), text: $draft.subject)
            .disabled(!editable)
        Text("${subject} will be replaced with the subject of the message you are responding to")
            .font(.caption)
            .foregroundStyle(.secondary)
        TextEditor(text: $draft.message)
            .frame(minHeight: 120)
            .disabled(!editable)
            .accessibilityLabel(String(localized: "Message"))
    }

    private func load() {
        draft = OutOfOfficeDraft(account: account, sieve: model.sieve, now: Date())
    }

    private func save() async {
        status = nil
        let outcome = await model.run(draft.command(accountId: account.id))
        if let message = CommandMessage.failure(outcome) {
            status = .failure(message)
        } else {
            status = .success(String(localized: "Autoresponder saved"))
            load()
        }
    }

    private func openAvailability() {
        guard let server = URL(string: account.serverURL) else { return }
        openURL(server.appending(path: "index.php/settings/user/availability"))
    }
}

/// §8.5 Sieve server: the connection the server uses for ManageSieve, through
/// `configureSieve`. Enabling it is what makes Autoresponder, Filters and the script editor
/// switch from the hint to their forms.
struct SieveServerSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var draft: SieveServerDraft?
    @State private var status: SettingsStatus?

    /// The form starts from the rows, so it needs no `onAppear` inside the shared form.
    init(model: AccountSettingsModel, account: AccountRecord) {
        self.model = model
        self.account = account
        _draft = State(initialValue: SieveServerDraft(account: account, sieve: model.sieve))
    }

    var body: some View {
        Section {
            Text(
                "Sieve is a powerful language for writing filters for your mailbox. You can manage the sieve "
                    + "scripts in Mail if your email service supports it. Sieve is also required to use "
                    + "Autoresponder and Filters."
            )
            .foregroundStyle(.secondary)
            if let draft = Binding($draft) {
                Toggle(String(localized: "Enable sieve filter"), isOn: draft.enabled)
                if draft.wrappedValue.enabled {
                    TextField(String(localized: "Sieve host"), text: draft.host)
                    Picker(String(localized: "Sieve security"), selection: draft.security) {
                        ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(String(localized: "Sieve Port"), value: draft.port, format: .number.grouping(.never))
                    Picker(String(localized: "Sieve credentials"), selection: draft.customCredentials) {
                        Text("IMAP credentials").tag(false)
                        Text("Custom").tag(true)
                    }
                    if draft.wrappedValue.customCredentials {
                        TextField(String(localized: "Sieve User"), text: draft.user)
                        SecureField(String(localized: "Sieve Password"), text: draft.password)
                    }
                }
                BusyButton(title: String(localized: "Save sieve settings"), isDisabled: !draft.wrappedValue.isValid) {
                    await save()
                }
            }
            SettingsStatusLine(status: status)
        } header: {
            Text("Sieve server")
        }
    }

    private func save() async {
        guard let draft else { return }
        status = nil
        let outcome = await model.run(.configureSieve(accountId: account.id, draft.request))
        if let message = CommandMessage.failure(outcome) {
            status = .failure(message)
        } else {
            status = .success(String(localized: "Sieve settings saved"))
            self.draft?.password = ""
        }
    }
}

/// §8.5 Sieve script editor: the active script, saved through `saveSieveScript`. A 422 is
/// the server's parser rejecting it; its message shows right under the text.
struct SieveScriptSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var script = ""
    @State private var loaded = false
    @State private var status: SettingsStatus?
    @Environment(\.ncTheme) private var theme

    var body: some View {
        Section {
            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 20 * 16)
                .disabled(!loaded)
                .accessibilityLabel(String(localized: "Sieve script"))
                .onAppear(perform: load)
                .onChange(of: model.sieve?.script) { _, _ in
                    if !loaded { load() }
                }
            BusyButton(title: String(localized: "Save sieve script"), isDisabled: !loaded) {
                await save()
            }
            SettingsStatusLine(status: status)
        } header: {
            Text("Sieve script editor")
        }
    }

    private func load() {
        guard let sieve = model.sieve, sieve.sieveEnabled, let text = sieve.script else { return }
        script = text
        loaded = true
    }

    private func save() async {
        status = nil
        let outcome = await model.run(.saveSieveScript(accountId: account.id, script: script))
        if let message = CommandMessage.sieveScriptFailure(outcome) {
            status = .failure(message)
        } else {
            status = .success(String(localized: "Sieve script saved"))
        }
    }
}
