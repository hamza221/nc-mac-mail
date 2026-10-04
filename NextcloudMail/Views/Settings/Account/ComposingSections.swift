// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8.3 Writing mode: saved on change through the queue. The radio follows the store, so a
/// refused patch rolls back with the row rather than leaving the control lying.
struct WritingModeSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    var body: some View {
        Section {
            Picker(
                String(localized: "Writing mode"),
                selection: Binding(
                    get: {
                        account.editorMode == AccountEditorMode.plain
                            ? AccountEditorMode.plain : AccountEditorMode.rich
                    },
                    set: { mode in Task { await model.patch(AccountPatch(editorMode: mode)) } }
                )
            ) {
                Text("Plain text").tag(AccountEditorMode.plain)
                Text("Rich text").tag(AccountEditorMode.rich)
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Writing mode")
        }
    }
}

/// §8.3 Signature: per identity, edited in the composer's own editor, saved through the queue.
struct SignatureSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    /// nil is the account's own signature; otherwise an alias's server id.
    @State private var identity: Int64?
    @State private var document = EditorDocument()
    @State private var current = ""
    @State private var measure: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Place signature above quoted text"),
                    isOn: Binding(
                        get: { account.signatureAboveQuote },
                        set: { value in Task { await model.patch(AccountPatch(signatureAboveQuote: value)) } }
                    ))
                if !model.aliases.isEmpty {
                    Picker(String(localized: "Identity"), selection: $identity) {
                        Text("\(account.name) (\(account.emailAddress))").tag(Int64?.none)
                        ForEach(model.aliases, id: \.remoteId) { alias in
                            Text("\(alias.name ?? alias.email) (\(alias.email))").tag(Int64?.some(alias.remoteId))
                        }
                    }
                }
            } header: {
                Text("Signature")
            }
            Section {
                ComposerEditor(document: document)
                    .frame(minHeight: 180)
                if SignatureRules.isLarge(current) {
                    NCNoteCard(.warning) {
                        Text(
                            "This signature is larger than 2 MB, usually because an image is embedded in it. "
                                + "It is added to every message you send and may slow down the editor.")
                    }
                }
                if SignatureRules.overridesPlainText(current, editorMode: account.editorMode) {
                    NCNoteCard(.warning) {
                        Text(
                            "This signature contains images. New messages will use rich text, even though "
                                + "your writing mode is set to plain text.")
                    }
                }
                HStack {
                    BusyButton(title: String(localized: "Save signature")) {
                        await save(serialized())
                    }
                    if !(storedSignature ?? "").isEmpty {
                        BusyButton(title: String(localized: "Delete"), role: .destructive) {
                            await save(nil)
                            load()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: identity) { _, _ in load() }
        .onChange(of: document.selection) { _, _ in scheduleMeasure() }
    }

    private var storedSignature: String? {
        guard let identity else { return account.signature }
        return model.aliases.first { $0.remoteId == identity }?.signature
    }

    /// Plain accounts get the plain editor so they cannot add images; a signature that
    /// already has one keeps rich text, or the image would be lost on save (the web's rule).
    private func load() {
        let signature = storedSignature ?? ""
        let rich = account.editorMode != AccountEditorMode.plain || SignatureText.hasImage(signature)
        let fresh = EditorDocument(mode: rich ? .rich : .plain)
        if SignatureText.isHTML(signature) {
            fresh.setHTML(signature)
        } else {
            fresh.setPlainText(signature)
        }
        document = fresh
        current = signature
    }

    private func serialized() -> String {
        document.mode == .rich ? document.html() : document.plainText()
    }

    /// Serialising a signature with an embedded image is not free, so the warnings follow
    /// the text after a short pause rather than on every keystroke.
    private func scheduleMeasure() {
        measure?.cancel()
        measure = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            current = serialized()
        }
    }

    private func save(_ signature: String?) async {
        let value = signature.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let identity {
            await model.perform(.setAliasSignature(aliasRemoteId: identity, signature: value))
        } else {
            await model.perform(.setSignature(value))
        }
    }
}

/// §8.3 Default folders: six pickers, each saved on change.
struct DefaultFoldersSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    @Environment(AppSession.self) private var session

    var body: some View {
        Section {
            ForEach(DefaultFolder.allCases) { role in
                InlineMailboxPicker(
                    title: role.title,
                    accountId: account.id,
                    store: session.store,
                    selection: Binding(
                        get: { model.localMailboxId(remote: role.remoteId(in: account)) },
                        set: { local in Task { await model.setDefaultFolder(role, localMailboxId: local) } }
                    )
                )
            }
        } header: {
            Text("Default folders")
        } footer: {
            Text(
                "The folders to use for drafts, sent messages, deleted messages, archived messages, snoozed messages and junk messages."
            )
        }
    }
}

/// §8.3 Automatic trash deletion: saved one second after the last keystroke.
struct TrashRetentionSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var text: String
    @State private var pending: Task<Void, Never>?

    /// The field starts from the row, so it needs no `onAppear` inside the shared form.
    init(model: AccountSettingsModel, account: AccountRecord) {
        self.model = model
        self.account = account
        _text = State(initialValue: TrashRetention.text(account.trashRetentionDays))
    }

    var body: some View {
        Section {
            TextField(
                String(localized: "Days after which messages in Trash will automatically be deleted:"), text: $text
            )
            .onChange(of: text) { _, value in schedule(value) }
            if TrashRetention.days(from: text) == nil {
                Text("Enter a whole number of days, 0 or more.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Automatic trash deletion")
        } footer: {
            Text(
                "Disable trash retention by leaving the field empty or setting it to 0. Only mails deleted "
                    + "after enabling trash retention will be processed.")
        }
    }

    private func schedule(_ value: String) {
        pending?.cancel()
        guard let days = TrashRetention.days(from: value),
            days != (account.trashRetentionDays ?? 0)
        else { return }
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await model.patch(AccountPatch(trashRetentionDays: days))
        }
    }
}

/// §8.3 Folder search, §8 Classification, §8.3 Calendar: one switch each, saved on change.
struct SwitchSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    let section: AccountSettingsSection

    var body: some View {
        Section {
            Toggle(label, isOn: Binding(get: { value }, set: { save($0) }))
        } header: {
            Text(section.title)
        }
    }

    private var label: String {
        switch section {
        case .folderSearch: String(localized: "Enable mail body search")
        case .classification: String(localized: "Enable mark as important classification")
        default: String(localized: "Automatically create tentative appointments in calendar")
        }
    }

    private var value: Bool {
        switch section {
        case .folderSearch: account.searchBody
        case .classification: account.classificationEnabled
        default: account.imipCreate
        }
    }

    private func save(_ on: Bool) {
        let patch =
            switch section {
            case .folderSearch: AccountPatch(searchBody: on)
            case .classification: AccountPatch(classificationEnabled: on)
            default: AccountPatch(imipCreate: on)
            }
        Task { await model.patch(patch) }
    }
}
