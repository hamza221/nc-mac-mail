// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// Per-account settings (WS-39, §8), hosted by the Settings window's Accounts tab.
///
/// Shows one ``AccountSettingsGroup`` page at a time; the Accounts tab owns the page list
/// (its sidebar) and the selection, so this view only renders the page it is given and
/// moves the binding when a section's "Go to…" asks for another page. The `@State` model
/// needs `session.store`, so it lives one level down in ``AccountSettingsHost``: a view's
/// `init` runs before its `@Environment` is populated.
struct AccountSettingsView: View {
    let accountId: Int64
    @Binding var group: AccountSettingsGroup

    @Environment(AppSession.self) private var session

    var body: some View {
        AccountSettingsHost(accountId: accountId, group: $group, store: session.store, services: .live(session))
    }
}

struct AccountSettingsHost: View {
    @State private var model: AccountSettingsModel
    @Binding var group: AccountSettingsGroup

    init(
        accountId: Int64, group: Binding<AccountSettingsGroup>, store: MailStore, services: AccountSettingsServices
    ) {
        _model = State(initialValue: AccountSettingsModel(accountId: accountId, store: store, services: services))
        _group = group
    }

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: model.sections) { _, sections in
                if !sections.isEmpty, !AccountSettingsGroup.visible(among: sections).contains(group) {
                    group = .general
                }
            }
            .alert(
                String(localized: "The change could not be saved."),
                isPresented: Binding(get: { model.queueError != nil }, set: { if !$0 { model.queueError = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) { model.queueError = nil }
            } message: {
                Text(model.queueError ?? "")
            }
    }

    @ViewBuilder
    private var page: some View {
        if let account = model.account {
            let sections = group.sections.filter(model.sections.contains)
            if let only = sections.first, sections.count == 1, only.ownsForm, !only.isLocked(for: account) {
                // Signature, Autoresponder, Filters, Quick actions, Mail server and Delegation
                // carry sheets and dialogs, so they keep their own form.
                section(only, account: account)
                    .id(group)
            } else if sections.isEmpty {
                ContentUnavailableView { Text("This account has no such settings.") }
            } else {
                Form {
                    ForEach(sections) { section in
                        self.section(section, account: account)
                    }
                }
                .formStyle(.grouped)
                .id(group)
            }
        } else {
            ContentUnavailableView { Text("This account is not mirrored yet.") }
        }
    }

    @ViewBuilder
    private func section(_ section: AccountSettingsSection, account: AccountRecord) -> some View {
        let goTo: (AccountSettingsSection) -> Void = { group = AccountSettingsGroup.containing($0) }
        if section.isLocked(for: account) {
            LockedSectionView(section: section)
        } else {
            switch section {
            case .aliases: AliasesSection(model: model, account: account, goTo: goTo)
            case .certificates: CertificatesSection(model: model, account: account)
            case .writingMode: WritingModeSection(model: model, account: account)
            case .signature: SignatureSection(model: model, account: account)
            case .defaultFolders: DefaultFoldersSection(model: model, account: account)
            case .trashRetention: TrashRetentionSection(model: model, account: account)
            case .folderSearch, .classification, .calendar:
                SwitchSection(model: model, account: account, section: section)
            case .autoresponder: AutoresponderSection(model: model, account: account, goTo: goTo)
            case .quickActions: QuickActionsSection(model: model, account: account)
            case .filters: FiltersSection(model: model, account: account, goTo: goTo)
            case .mailServer: MailServerSection(model: model, account: account)
            case .sieveServer: SieveServerSection(model: model, account: account)
            case .sieveScript: SieveScriptSection(model: model, account: account)
            case .delegation: DelegationSection(model: model, account: account)
            }
        }
    }
}
