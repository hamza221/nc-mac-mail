// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// "Add mail account" (ux-spec § Mail account setup (WS-40)), presented as a sheet by
/// Settings → General (WS-38) for one signed-in login.
struct AccountSetupSheet: View {
    let sessionId: String
    /// Called with the new account's id once it is created and loading, or nil on Cancel.
    let onFinished: (Int64?) -> Void

    @Environment(AppSession.self) private var session
    @State private var model: AccountSetupModel?

    var body: some View {
        Group {
            if let model {
                AccountSetupFormView(model: model, onCancel: { close(model) })
            } else {
                NCNoteCard(.error) { Text("This account is signed out. Sign in again to add a mail account.") }
                    .padding()
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 420)
        .task { build() }
        .onChange(of: model?.createdAccountId) { _, accountId in
            guard let accountId else { return }
            Task { await finish(accountId) }
        }
        .onDisappear {
            model?.cancel(); model?.stop()
        }
    }

    private func build() {
        guard model == nil, let account = session.accounts.first(where: { $0.id == sessionId }) else { return }
        let engine = session.engine
        let sessionId = sessionId
        let built = AccountSetupModel(
            store: session.store,
            identity: account.identity,
            run: { command in
                guard let commands = engine.settingsCommands(sessionId: sessionId) else {
                    return .failure(.transport(SidebarServiceError.loginNotRunning))
                }
                return await commands.run(command)
            },
            consent: OAuthConsentSession()
        )
        built.start()
        model = built
    }

    private func close(_ model: AccountSetupModel) {
        model.cancel()
        onFinished(nil)
    }

    /// The web client redirects to the new account's mailbox view; here the sidebar selects
    /// its inbox.
    private func finish(_ accountId: Int64) async {
        let mailboxes = (try? await session.store.mailboxes(accountId: accountId)) ?? []
        if let inbox = mailboxes.first(where: { $0.specialRole == "inbox" }) ?? mailboxes.first {
            session.navigation.selectMailbox(inbox.id)
        }
        onFinished(accountId)
    }
}

/// The form itself, over a model — separate so previews and tests need no `AppSession`.
struct AccountSetupFormView: View {
    @Bindable var model: AccountSetupModel
    let onCancel: () -> Void

    @Environment(\.ncTheme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.allowsNewAccounts == false {
                NCNoteCard(.info) { Text("To add a mail account, please contact your administrator.") }
                    .padding(theme.metrics.spacing.loose)
                Spacer()
            } else {
                Form {
                    Section {
                        Picker(String(localized: "Mail server configuration mode"), selection: modeBinding) {
                            Text("Auto").tag(AccountSetupForm.Mode.auto)
                            Text("Manual").tag(AccountSetupForm.Mode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    identitySection
                    if model.form.mode == .auto {
                        autoSection
                    } else {
                        serverSection(imap: true)
                        serverSection(imap: false)
                    }
                    providerHint
                    feedbackSection
                }
                .formStyle(.grouped)
                .disabled(model.isRunning)
            }
            Divider()
            buttons
        }
        .onAppear { nameFocused = true }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            TextField(String(localized: "Name"), text: $model.form.accountName)
                .focused($nameFocused)
            TextField(
                String(localized: "Mail address"), text: $model.form.emailAddress, prompt: Text("name@example.org")
            )
            .textContentType(.emailAddress)
            if model.form.showsEmailFormatHint {
                Text("Please enter an email of the format name@example.com")
                    .font(.callout)
                    .foregroundStyle(theme.colors.error.element)
            }
        }
    }

    private var autoSection: some View {
        Section {
            SecureField(String(localized: "Password"), text: $model.form.password)
            Toggle(
                String(localized: "Enable mark as important classification"), isOn: $model.form.classificationEnabled)
        }
    }

    @ViewBuilder
    private func serverSection(imap: Bool) -> some View {
        Section {
            TextField(imap ? String(localized: "IMAP Host") : String(localized: "SMTP Host"), text: host(imap))
            Picker(
                imap ? String(localized: "IMAP Security") : String(localized: "SMTP Security"),
                selection: security(imap)
            ) {
                ForEach(AccountSetupForm.Security.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(
                imap ? String(localized: "IMAP Port") : String(localized: "SMTP Port"),
                value: port(imap), format: .number.grouping(.never))
            TextField(imap ? String(localized: "IMAP User") : String(localized: "SMTP User"), text: user(imap))
            if !model.form.usesOAuth {
                SecureField(
                    imap ? String(localized: "IMAP Password") : String(localized: "SMTP Password"), text: password(imap)
                )
            }
            if !imap {
                Toggle(
                    String(localized: "Enable mark as important classification"),
                    isOn: $model.form.classificationEnabled)
            }
        } header: {
            Text(imap ? "IMAP Settings" : "SMTP Settings")
        }
    }

    @ViewBuilder
    private var providerHint: some View {
        if !model.form.usesOAuth, let provider = model.form.provider {
            Section {
                NCNoteCard(.info) {
                    switch provider {
                    case .google:
                        Text(
                            "Google requires OAuth authentication. If your Nextcloud admin has not configured Google OAuth, you can use a Google App Password instead."
                        )
                    case .microsoft:
                        Text(
                            "Microsoft requires OAuth authentication. Ask your Nextcloud admin to configure Microsoft OAuth in the admin settings."
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let feedback = model.feedback {
            Section {
                Text(feedback.text)
                    .foregroundStyle(
                        feedback.isError ? AnyShapeStyle(theme.colors.error.element) : AnyShapeStyle(.secondary)
                    )
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            if model.allowsNewAccounts != false {
                Button(action: model.submit) {
                    HStack(spacing: theme.metrics.spacing.tight) {
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Text(model.buttonLabel)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || !model.form.canSubmit)
            }
        }
        .padding(theme.metrics.spacing.loose)
    }

    // MARK: - Bindings through the form's coupling rules

    private var modeBinding: Binding<AccountSetupForm.Mode> {
        Binding(get: { model.form.mode }, set: { model.form.setMode($0) })
    }

    private func host(_ imap: Bool) -> Binding<String> {
        Binding(
            get: { imap ? model.form.imapHost : model.form.smtpHost },
            set: { imap ? model.form.setIMAPHost($0) : model.form.setSMTPHost($0) })
    }

    private func user(_ imap: Bool) -> Binding<String> {
        Binding(
            get: { imap ? model.form.imapUser : model.form.smtpUser },
            set: { imap ? model.form.setIMAPUser($0) : model.form.setSMTPUser($0) })
    }

    private func password(_ imap: Bool) -> Binding<String> {
        Binding(
            get: { imap ? model.form.imapPassword : model.form.smtpPassword },
            set: { imap ? model.form.setIMAPPassword($0) : model.form.setSMTPPassword($0) })
    }

    private func port(_ imap: Bool) -> Binding<Int> {
        Binding(
            get: { imap ? model.form.imapPort : model.form.smtpPort },
            set: { imap ? (model.form.imapPort = $0) : model.form.setSMTPPort($0) })
    }

    private func security(_ imap: Bool) -> Binding<AccountSetupForm.Security> {
        Binding(
            get: { imap ? model.form.imapSecurity : model.form.smtpSecurity },
            set: { imap ? model.form.setIMAPSecurity($0) : model.form.setSMTPSecurity($0) })
    }
}
