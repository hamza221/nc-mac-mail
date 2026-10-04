// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// Per-account settings (WS-39, §8), hosted by the Settings window's Accounts tab.
///
/// A section list on the left, the selected section's form on the right. The `@State`
/// model needs `session.store`, so it lives one level down in ``AccountSettingsHost``: a
/// view's `init` runs before its `@Environment` is populated.
struct AccountSettingsView: View {
    let accountId: Int64

    @Environment(AppSession.self) private var session

    init(accountId: Int64) {
        self.accountId = accountId
    }

    var body: some View {
        AccountSettingsHost(accountId: accountId, store: session.store, services: .live(session))
    }
}

struct AccountSettingsHost: View {
    @State private var model: AccountSettingsModel
    @State private var selection: AccountSettingsSection? = .aliases
    @Environment(\.ncTheme) private var theme

    init(accountId: Int64, store: MailStore, services: AccountSettingsServices) {
        _model = State(initialValue: AccountSettingsModel(accountId: accountId, store: store, services: services))
    }

    var body: some View {
        HStack(spacing: 0) {
            List(model.sections, selection: $selection) { section in
                Text(section.title).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.sections) { _, sections in
            if let selection, !sections.contains(selection) { self.selection = sections.first }
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
    private var detail: some View {
        if let account = model.account, let section = selection, model.sections.contains(section) {
            if section.isLocked(for: account) {
                LockedSectionView(section: section)
            } else {
                content(section, account: account)
                    .id(section)
            }
        } else if model.account == nil {
            ContentUnavailableView { Text("This account is not mirrored yet.") }
        } else {
            ContentUnavailableView { Text("Select a section") }
        }
    }

    @ViewBuilder
    private func content(_ section: AccountSettingsSection, account: AccountRecord) -> some View {
        let goTo: (AccountSettingsSection) -> Void = { selection = $0 }
        switch section {
        case .aliases: AliasesSection(model: model, account: account, goTo: goTo)
        case .certificates: CertificatesSection(model: model, account: account)
        case .writingMode: WritingModeSection(model: model, account: account)
        case .signature: SignatureSection(model: model, account: account)
        case .defaultFolders: DefaultFoldersSection(model: model, account: account)
        case .trashRetention: TrashRetentionSection(model: model, account: account)
        case .folderSearch, .classification, .calendar: SwitchSection(model: model, account: account, section: section)
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
