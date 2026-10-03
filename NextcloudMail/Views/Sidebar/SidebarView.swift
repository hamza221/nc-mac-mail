// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// The first column: every account, every mailbox, in the right order, with unread counts.
///
/// `RootSplitView` owns the `SidebarStore` and passes it in with the shared `NavigationState`;
/// selection lives there, so the list and the message list agree on one mailbox.
struct SidebarView: View {
    @Bindable var model: SidebarStore
    let navigation: NavigationState

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(model.accounts) { account in
                Section {
                    ForEach(model.mailboxNodes[account.id] ?? []) { node in
                        MailboxTreeRowView(node: node, accountId: account.id, model: model)
                    }
                } header: {
                    NCNavigationCaption(account.name) {
                        AccountActionsMenu(account: account, model: model)
                    }
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $model.infoTarget) { target in
            MailboxInfoView(model: model.infoModel(for: target))
        }
    }

    /// `List(selection:)` binds one value across every account's section: a real
    /// `MailboxRecord.id` is unique mirror-wide (ADR-0033), so this stays correct with any
    /// number of accounts, and a non-selectable node simply never carries a `.tag` that could
    /// be assigned into it.
    private var selectionBinding: Binding<Int64?> {
        Binding(get: { navigation.selectedMailboxID }, set: { navigation.selectMailbox($0) })
    }
}

/// One row of the tree, recursively: a plain row for a leaf, a `DisclosureGroup` for anything
/// with children. `NCNavigationItem` has no `children:` slot by design -- its own doc comment
/// says nesting is `DisclosureGroup`'s job, not a hand-rolled copy of it.
private struct MailboxTreeRowView: View {
    let node: MailboxNode
    let accountId: Int64
    @Bindable var model: SidebarStore

    var body: some View {
        if node.children.isEmpty {
            label.tagged(node)
        } else {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    MailboxTreeRowView(node: child, accountId: accountId, model: model)
                }
            } label: {
                label
            }
            .tagged(node)
        }
    }

    /// `NCNavigationItem` composes cleanly as a `DisclosureGroup` label -- no fighting the
    /// library's alignment the way `NCListItem`'s single leading slot forced WS-08 to
    /// (`docs/feedback/library-feedback.md`). This row only ever needs one icon and one count,
    /// which is the shape the component already has.
    private var label: some View {
        NCNavigationItem(node.displayName, icon: icon, count: node.unreadCount)
            // Unsubscribed mailboxes open but are not mirrored (ADR-0007); the secondary
            // style is the whole difference, so it stays on the outer view and cascades into
            // the plain `Text` the component draws rather than needing a colour parameter the
            // library does not expose.
            .foregroundStyle(node.isSubscribed ? .primary : .secondary)
            // `NCNavigationItem` does not combine its children the way `NCListItem` does --
            // see this workstream's library-feedback entry. Without this, VoiceOver reads the
            // name and the count as two separate stops instead of the one the brief asks for.
            .accessibilityElement(children: .combine)
            .contextMenu { contextMenuItems }
            // A failed sync is retried on its own, so it gets no badge or dialogue -- only a
            // tooltip pointing at Get info, which says why (ux-spec.md, "Errors"). An empty
            // help string shows no tooltip at all.
            .help(syncFailureHelp)
    }

    private var syncFailureHelp: String {
        guard node.row?.hasSyncFailure == true else { return "" }
        return String(localized: "The last sync of this folder failed. Choose Get info for details.")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let row = node.row {
            Button("Mark all as read") { model.markAllRead(accountId: accountId, mailboxId: row.id) }
            Button("Refresh") { model.refreshMailbox(accountId: accountId, mailboxId: row.id) }
            Button("Get info") { model.getInfo(accountId: accountId, mailboxId: row.id) }
        }
    }

    private var icon: NCSymbol {
        switch node.row?.specialRole?.lowercased() {
        case "inbox": MailSymbol.inbox.symbol
        case "drafts": MailSymbol.drafts.symbol
        case "sent": MailSymbol.sent.symbol
        case "archive": MailSymbol.archive.symbol
        case "junk": MailSymbol.junk.symbol
        case "trash": MailSymbol.trash.symbol
        default: MailSymbol.folder.symbol
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { model.isExpanded(accountId: accountId, node: node) },
            set: { model.setExpanded($0, accountId: accountId, node: node) }
        )
    }
}

/// The account header's trailing control: refresh, storage, sign out.
///
/// A separate type rather than a closure inline in `SidebarView`, because `NCNavigationCaption`
/// takes its trailing content through `@ViewBuilder`, and a menu with three destinations reads
/// better named than built in place.
private struct AccountActionsMenu: View {
    let account: AccountRecord
    let model: SidebarStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Button("Refresh") { model.refreshAccount(account) }
            Button("Storage…") {
                model.showStorage(account)
                openSettings()
            }
            Divider()
            Button("Sign out", role: .destructive) {
                model.signOut(account)
                openSettings()
            }
        } label: {
            NCIcon(.dotsHorizontal, label: .decorative)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .ncAccessibilityLabel(.text("\(account.name) actions"))
    }
}

extension View {
    /// Tags a row with its mailbox's local id, only when the row can actually be selected --
    /// a `\noselect` or synthetic container never gets a `.tag`, which is what makes selecting
    /// one impossible rather than merely discouraged.
    @ViewBuilder
    fileprivate func tagged(_ node: MailboxNode) -> some View {
        if node.isSelectable, let id = node.row?.id {
            tag(id)
        } else {
            self
        }
    }
}
