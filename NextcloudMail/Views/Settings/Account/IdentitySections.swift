// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8.1: the primary identity, the aliases, and the add form. Every write is queued, so an
/// alias added offline shows at once under its placeholder id (ADR-0081).
struct AliasesSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    let goTo: (AccountSettingsSection) -> Void

    @State private var editing: Int64?
    @State private var editName = ""
    @State private var editEmail = ""
    @State private var adding = false
    @State private var newName = ""
    @State private var newEmail = ""

    private var isProvisioned: Bool { account.provisioningId != nil }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("**\(account.name)** <\(account.emailAddress)>")
                    Spacer()
                    if !isProvisioned, model.sections.contains(.mailServer) {
                        Button(String(localized: "Edit")) { goTo(.mailServer) }
                            .help(String(localized: "Change the name and address in Mail server"))
                    }
                }
                ForEach(model.aliases, id: \.remoteId) { alias in
                    row(alias)
                }
            } header: {
                Text("Aliases")
            }
            if !isProvisioned {
                Section {
                    if adding {
                        TextField(String(localized: "Name"), text: $newName)
                        TextField(String(localized: "Email address"), text: $newEmail)
                        HStack {
                            Button(String(localized: "Cancel")) { resetAdd() }
                            BusyButton(
                                title: String(localized: "Create alias"),
                                isDisabled: !Self.isValid(name: newName, email: newEmail)
                            ) {
                                if await model.perform(.createAlias(email: trimmed(newEmail), name: trimmed(newName))) {
                                    resetAdd()
                                }
                            }
                        }
                    } else {
                        Button(String(localized: "Add alias")) {
                            newName = account.name
                            newEmail = ""
                            adding = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ alias: AliasRecord) -> some View {
        if editing == alias.remoteId {
            VStack(alignment: .leading) {
                TextField(String(localized: "Name"), text: $editName)
                TextField(String(localized: "Email address"), text: $editEmail)
                    .disabled(alias.provisioned)
                HStack {
                    Button(String(localized: "Cancel")) { editing = nil }
                    BusyButton(
                        title: String(localized: "Update alias"),
                        isDisabled: !Self.isValid(name: editName, email: editEmail)
                    ) {
                        let saved = await model.perform(
                            .updateAlias(
                                aliasRemoteId: alias.remoteId,
                                email: alias.provisioned ? alias.email : trimmed(editEmail),
                                name: trimmed(editName)))
                        if saved { editing = nil }
                    }
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading) {
                    Text(alias.name ?? alias.email).font(.headline)
                    Text(alias.email).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Rename alias")) {
                    editName = alias.name ?? ""
                    editEmail = alias.email
                    editing = alias.remoteId
                }
                if !alias.provisioned {
                    Button(String(localized: "Delete alias"), role: .destructive) {
                        Task { await model.perform(.deleteAlias(aliasRemoteId: alias.remoteId)) }
                    }
                }
            }
        }
    }

    private func resetAdd() {
        adding = false
        newName = ""
        newEmail = ""
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    static func isValid(name: String, email: String) -> Bool {
        let address = email.trimmingCharacters(in: .whitespaces)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && address.contains("@") && !address.contains(" ")
    }
}

/// §8.2: link one identity to an S/MIME certificate through the `setAliasCertificate`
/// command. The list is the mirror's certificates for the login, filtered per identity.
struct CertificatesSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    /// nil is the primary identity, otherwise an alias's server id.
    @State private var identity: Int64??
    @State private var certificate: Int64?
    @State private var status: SettingsStatus?

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Select an alias"), selection: $identity) {
                    Text("Select an alias").tag(Int64??.none)
                    Text("\(account.name) <\(account.emailAddress)>").tag(Int64??.some(nil))
                    ForEach(model.aliases, id: \.remoteId) { alias in
                        Text("\(alias.name ?? alias.email) <\(alias.email)>").tag(Int64??.some(alias.remoteId))
                    }
                }
                .onChange(of: identity) { _, _ in
                    certificate = currentLink
                    status = nil
                }
                if identity != nil {
                    Picker(String(localized: "Certificate"), selection: $certificate) {
                        Text("No certificate").tag(Int64?.none)
                        ForEach(eligible, id: \.remoteId) { certificate in
                            Text(CertificateRules.label(certificate)).tag(Int64?.some(certificate.remoteId))
                        }
                    }
                    if let chosen = eligible.first(where: { $0.remoteId == certificate }),
                        !CertificateRules.isChainVerified(chosen)
                    {
                        NCNoteCard(.warning) {
                            Text(
                                "The selected certificate is not trusted by the server. Recipients might not be "
                                    + "able to verify your signature.")
                        }
                    }
                    BusyButton(title: String(localized: "Update Certificate"), isDisabled: certificate == currentLink) {
                        await update()
                    }
                    SettingsStatusLine(status: status)
                }
            } header: {
                Text("Alias to S/MIME certificate mapping")
            }
        }
        .formStyle(.grouped)
    }

    private var email: String? {
        switch identity {
        case .some(.none): account.emailAddress
        case .some(.some(let remoteId)): model.aliases.first { $0.remoteId == remoteId }?.email
        case .none: nil
        }
    }

    private var currentLink: Int64? {
        switch identity {
        case .some(.none): account.smimeCertificateRemoteId
        case .some(.some(let remoteId)): model.aliases.first { $0.remoteId == remoteId }?.smimeCertificateRemoteId
        case .none: nil
        }
    }

    private var eligible: [SmimeCertificateRecord] {
        guard let email else { return [] }
        return CertificateRules.eligible(model.certificates, email: email, now: Date())
    }

    private func update() async {
        guard case .some(let aliasRemoteId) = identity else { return }
        let outcome = await model.run(
            .setAliasCertificate(
                accountId: account.id, aliasRemoteId: aliasRemoteId, certificateRemoteId: certificate))
        status =
            outcome.isSuccess
            ? .success(String(localized: "Certificate updated"))
            : .failure(String(localized: "Could not update certificate"))
    }
}
