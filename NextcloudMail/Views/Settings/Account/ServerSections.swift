// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8 Mail server: the IMAP and SMTP connection, prefilled from the account, saved through
/// `updateMailServer` (online only, ADR-0068). The command re-reads the account after the
/// PUT, so the form refills from a complete row.
struct MailServerSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var draft: MailServerDraft?
    @State private var status: SettingsStatus?
    /// Set once a test ran in this view, so an older verdict in the row is not shown as this one.
    @State private var tested = false

    var body: some View {
        Form {
            if let draft = Binding($draft) {
                Section {
                    TextField(String(localized: "IMAP Host"), text: draft.imapHost)
                    Picker(String(localized: "IMAP Security"), selection: draft.imapSecurity) {
                        ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(String(localized: "IMAP Port"), value: draft.imapPort, format: .number.grouping(.never))
                    TextField(String(localized: "IMAP User"), text: draft.imapUser)
                    if !draft.wrappedValue.usesOAuth {
                        SecureField(String(localized: "IMAP Password"), text: draft.imapPassword)
                    }
                } header: {
                    Text("IMAP")
                }
                Section {
                    TextField(String(localized: "SMTP Host"), text: draft.smtpHost)
                    Picker(String(localized: "SMTP Security"), selection: draft.smtpSecurity) {
                        ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField(String(localized: "SMTP Port"), value: draft.smtpPort, format: .number.grouping(.never))
                    TextField(String(localized: "SMTP User"), text: draft.smtpUser)
                    if !draft.wrappedValue.usesOAuth {
                        SecureField(String(localized: "SMTP Password"), text: draft.smtpPassword)
                    }
                } header: {
                    Text("SMTP")
                } footer: {
                    Text("Leave a password empty to keep the one the server has.")
                }
                Section {
                    HStack {
                        BusyButton(title: String(localized: "Save"), isDisabled: !draft.wrappedValue.isValid) {
                            await save()
                        }
                        BusyButton(title: String(localized: "Test connection")) {
                            await test()
                        }
                    }
                    if tested, let ok = model.connectionOK {
                        SettingsStatusLine(
                            status: ok
                                ? .success(String(localized: "Connection successful"))
                                : .failure(String(localized: "Could not connect")))
                    }
                    SettingsStatusLine(status: status)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = MailServerDraft(account: account) }
    }

    private func save() async {
        guard let draft else { return }
        status = nil
        let outcome = await model.run(.updateMailServer(accountId: account.id, draft.request))
        if let message = CommandMessage.failure(outcome) {
            status = .failure(message)
        } else {
            status = .success(String(localized: "Mail server saved"))
            self.draft?.imapPassword = ""
            self.draft?.smtpPassword = ""
        }
    }

    private func test() async {
        status = nil
        tested = false
        let outcome = await model.run(.testConnection(accountId: account.id))
        if let message = CommandMessage.failure(outcome) {
            status = .failure(message)
        } else {
            tested = true
        }
    }
}

/// §8.8 Delegation: who may send, receive and delete mail on this account's behalf. Both
/// writes are commands; the list is the mirror's `delegation` rows, which the command
/// re-reads.
struct DelegationSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var adding = false
    @State private var term = ""
    @State private var picked: AccountSettingsModel.Sharee?
    @State private var revoking: DelegationRecord?
    @State private var status: SettingsStatus?

    var body: some View {
        Form {
            Section {
                Text("Allow users to send, receive, and delete mail on your behalf")
                    .foregroundStyle(.secondary)
                ForEach(model.delegations, id: \.userId) { delegation in
                    HStack {
                        Text(delegation.displayName ?? delegation.userId)
                        Spacer()
                        Button(String(localized: "Revoke access"), role: .destructive) { revoking = delegation }
                    }
                }
                if adding {
                    TextField(String(localized: "Search users"), text: $term)
                        .onChange(of: term) { _, value in
                            picked = nil
                            model.searchDelegates(value)
                        }
                    ForEach(model.sharees) { sharee in
                        Button {
                            picked = sharee
                        } label: {
                            HStack {
                                Text(sharee.displayName)
                                Text(sharee.userId).foregroundStyle(.secondary)
                                Spacer()
                                if picked == sharee { Text("Selected").foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Button(String(localized: "Cancel")) { resetAdd() }
                        BusyButton(title: String(localized: "Delegate access"), isDisabled: picked == nil) {
                            await delegate()
                        }
                    }
                } else {
                    Button(String(localized: "Add delegate")) { adding = true }
                }
                SettingsStatusLine(status: status)
            } header: {
                Text("Delegation")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            String(localized: "Revoke access?"),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { delegation in
            Button(String(localized: "Revoke access"), role: .destructive) {
                Task { await revoke(delegation) }
            }
        } message: { delegation in
            Text(
                String(
                    format: String(localized: "%@ will no longer be able to act on your behalf"),
                    delegation.displayName ?? delegation.userId))
        }
    }

    private func delegate() async {
        guard let picked else { return }
        let outcome = await model.run(.delegate(accountId: account.id, userId: picked.userId))
        if outcome.isSuccess {
            status = .success(String(format: String(localized: "Delegated access to %@"), picked.displayName))
            resetAdd()
        } else {
            status = .failure(String(localized: "Could not delegate access"))
        }
    }

    private func revoke(_ delegation: DelegationRecord) async {
        let outcome = await model.run(.revokeDelegation(accountId: account.id, userId: delegation.userId))
        let name = delegation.displayName ?? delegation.userId
        status =
            outcome.isSuccess
            ? .success(String(format: String(localized: "Revoked access for %@"), name))
            : .failure(String(localized: "Could not revoke delegation"))
    }

    private func resetAdd() {
        adding = false
        term = ""
        picked = nil
        model.searchDelegates("")
    }
}
