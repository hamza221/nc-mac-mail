// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// The §3.3 folder menu, as a context menu on a real folder. Each item's condition is the web
/// client's: ACL rights from `myAcls`, special folders and folders with subfolders protected.
/// Every change is queued; Repair is the one command.
struct FolderMenu: View {
    let row: MailboxTreeRow
    let node: MailboxNode
    let account: AccountRecord
    let model: SidebarStore
    let navigation: NavigationState

    var body: some View {
        Text(infoLine)
        Divider()
        if row.allows("s") {
            Button("Mark all as read") { Task { await model.markFolderRead(row, accountId: account.id) } }
        }
        if row.hasDelimiter, row.allows("k") {
            Button("Add subfolder…") {
                model.prompt = .addSubfolder(parent: row, node: node, accountId: account.id)
            }
        }
        if !hasChildren, row.allows("x") {
            Button("Rename…") { model.prompt = .rename(row: row, accountId: account.id) }
        }
        if !isSpecial, row.hasDelimiter, !hasChildren, row.allows("x") {
            Button("Move folder…") { model.moveSource = SidebarStore.MoveSource(row: row, accountId: account.id) }
        }
        Button("Repair folder") { Task { await model.repairFolder(row, accountId: account.id) } }
            .disabled(model.isRepairBlocked(row.id))
        Divider()
        Toggle(
            "Subscribed",
            isOn: Binding(
                get: { row.isSubscribed },
                set: { value in Task { await model.setSubscribed(value, row: row, accountId: account.id) } }
            ))
        if row.specialRole?.lowercased() != "inbox" {
            Toggle(
                "Sync in background",
                isOn: Binding(
                    get: { row.syncInBackground },
                    set: { value in Task { await model.setSyncInBackground(value, row: row, accountId: account.id) } }
                ))
        }
        Divider()
        Button("Refresh") { model.refreshMailbox(accountId: account.id, mailboxId: row.id) }
        Button("Get info") { model.getInfo(accountId: account.id, mailboxId: row.id) }
        if row.allows("te") || (!isSpecial && !hasChildren && row.allows("x")) {
            Divider()
        }
        if row.allows("te") {
            Button("Delete all messages…", role: .destructive) {
                model.confirmation = .clearFolder(row: row, accountId: account.id)
            }
        }
        if !isSpecial, !hasChildren, row.allows("x") {
            Button("Delete folder…", role: .destructive) {
                model.confirmation = .deleteFolder(row: row, accountId: account.id)
            }
        }
    }

    private var hasChildren: Bool { !node.children.isEmpty }

    private var isSpecial: Bool { row.specialRole != nil }

    /// "Loading …" until a folder refresh reported a total -- the mirror's figure, never a
    /// request from here.
    private var infoLine: String {
        guard let total = row.totalCount else { return String(localized: "Loading …") }
        if row.unreadCount > 0 {
            return String(localized: "\(row.unreadCount) unread of \(total)")
        }
        return String(localized: "\(total) messages")
    }
}

/// The account caption's trailing menu (§3.2), plus v1's Refresh, Storage and Sign out.
struct AccountActionsMenu: View {
    let account: AccountRecord
    let model: SidebarStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            if model.isDisabled(account) {
                Text("Provisioned account is disabled")
                Text(
                    """
                    Please login using a password to enable this account. The current session is \
                    using passwordless authentication, e.g. SSO or WebAuthn.
                    """)
            } else {
                items
            }
        } label: {
            NCIcon(.dotsHorizontal, label: .decorative)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .ncAccessibilityLabel(.text("\(account.emailAddress) actions"))
    }

    @ViewBuilder
    private var items: some View {
        if let quota = model.quotaText(for: account) {
            Text(quota)
            Divider()
        }
        Button("Refresh") { model.refreshAccount(account) }
        Button("Account settings…") {
            model.openAccountSettings(account)
            openSettings()
        }
        if model.canDelegate(account) {
            Button("Delegate account…") { model.delegationAccount = account }
        }
        Button("Storage…") {
            model.showStorage(account)
            openSettings()
        }
        Divider()
        Toggle(
            "Show only subscribed folders",
            isOn: Binding(
                get: { account.showSubscribedOnly },
                set: { value in Task { await model.setShowSubscribedOnly(value, account: account) } }
            ))
        Button("Add folder…") { model.prompt = .addFolder(accountId: account.id) }
        if !isFirst {
            Button("Move up") { Task { await model.moveAccount(account, up: true) } }
        }
        if !isLast {
            Button("Move down") { Task { await model.moveAccount(account, up: false) } }
        }
        Divider()
        if model.canRemove(account) {
            Button("Remove account…", role: .destructive) { model.confirmation = .removeAccount(account) }
        }
        Button("Sign out", role: .destructive) {
            model.signOut(account)
            openSettings()
        }
    }

    private var isFirst: Bool { model.accounts.first?.id == account.id }
    private var isLast: Bool { model.accounts.last?.id == account.id }
}

/// The prompt, confirmation and error alerts, in one place so `SidebarView.body` stays a
/// list.
struct SidebarDialogs: ViewModifier {
    @Bindable var model: SidebarStore
    let navigation: NavigationState

    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(model.prompt?.title ?? "", isPresented: isPresented(\.prompt), presenting: model.prompt) { prompt in
                TextField("Folder name", text: $text)
                Button(isRename(prompt) ? "Rename" : "Create") { submit(prompt) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.prompt?.id) {
                text = model.prompt?.initialText ?? ""
            }
            .alert(
                confirmationTitle, isPresented: isPresented(\.confirmation), presenting: model.confirmation
            ) { confirmation in
                Button(confirmationButton(confirmation), role: .destructive) { confirm(confirmation) }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmationMessage(confirmation))
            }
            .alert(model.alert?.title ?? "", isPresented: isPresented(\.alert), presenting: model.alert) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                if let message = alert.message { Text(message) }
            }
    }

    private func isPresented<Value>(_ keyPath: ReferenceWritableKeyPath<SidebarStore, Value?>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } }
        )
    }

    private func isRename(_ prompt: SidebarPrompt) -> Bool {
        if case .rename = prompt { return true }
        return false
    }

    private func submit(_ prompt: SidebarPrompt) {
        let input = text
        Task {
            switch prompt {
            case .addFolder(let accountId):
                await model.createFolder(named: input, accountId: accountId)
            case .addSubfolder(let parent, let node, let accountId):
                await model.createSubfolder(named: input, parent: parent, accountId: accountId, node: node)
            case .rename(let row, let accountId):
                await model.renameFolder(row, to: input, accountId: accountId)
            }
        }
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case .removeAccount: String(localized: "Remove account")
        case .clearFolder(let row, _):
            String(localized: "Clear mailbox \(row.pathComponents.last ?? row.name)")
        case .deleteFolder(let row, _):
            String(localized: "Delete folder \(row.pathComponents.last ?? row.name)")
        case nil: ""
        }
    }

    private func confirmationMessage(_ confirmation: SidebarConfirmation) -> String {
        switch confirmation {
        case .removeAccount(let account):
            String(
                localized: """
                    The account for \(account.emailAddress) and cached email data will be removed from \
                    Nextcloud, but not from your email provider.
                    """)
        case .clearFolder: String(localized: "All messages in mailbox will be deleted.")
        case .deleteFolder: String(localized: "The folder and all messages in it will be deleted.")
        }
    }

    private func confirmationButton(_ confirmation: SidebarConfirmation) -> String {
        switch confirmation {
        case .removeAccount(let account): String(localized: "Remove \(account.emailAddress)")
        case .clearFolder: String(localized: "Clear folder")
        case .deleteFolder: String(localized: "Delete folder")
        }
    }

    private func confirm(_ confirmation: SidebarConfirmation) {
        Task {
            switch confirmation {
            case .removeAccount(let account):
                await model.removeAccount(account)
            case .clearFolder(let row, let accountId):
                await model.clearFolder(row, accountId: accountId)
            case .deleteFolder(let row, let accountId):
                // A deleted folder cannot stay selected; the web client goes to Priority inbox.
                if navigation.selection == .mailbox(row.id) { navigation.select(.priorityInbox) }
                await model.deleteFolder(row, accountId: accountId)
            }
        }
    }
}
