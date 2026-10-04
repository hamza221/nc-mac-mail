// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// The first column: New message, the virtual inboxes, every account's folders, the Outbox and
/// Mail settings -- §3.1 of the web client, laid out by `MailboxTree.layout(accounts:outboxCount:)`
/// ([ux-spec.md](../../../docs/product/ux-spec.md#sidebar-and-mailbox-management-ws-28)).
///
/// `RootSplitView` owns the `SidebarStore` and passes it in with the shared `NavigationState`;
/// selection lives there, so the sidebar and the content column agree on one
/// `SidebarSelection`. The engines the menus write through come from the environment's
/// `AppSession` (``SidebarServices/live(_:)``).
struct SidebarView: View {
    @Bindable var model: SidebarStore
    let navigation: NavigationState

    @Environment(AppSession.self) private var session
    @Environment(\.openComposer) private var openComposer
    @Environment(\.openSettings) private var openSettings
    @Environment(\.ncTheme) private var theme

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach(model.layout.virtualEntries, id: \.self) { entry in
                    VirtualEntryRow(entry: entry)
                }
            }
            ForEach(model.accounts) { account in
                Section {
                    AccountSectionContent(account: account, model: model, navigation: navigation)
                } header: {
                    NCNavigationCaption(account.emailAddress) {
                        AccountActionsMenu(account: account, model: model)
                    }
                }
            }
            // Contacts section: WS-35's, standing exception 1 in docs/delivery/workstreams.md.
            ContactsSidebarSection()
            Section {
                if let count = model.layout.outboxCount {
                    NCNavigationItem(String(localized: "Outbox"), icon: MailSymbol.outbox.symbol, count: count)
                        .accessibilityElement(children: .combine)
                        .tag(SidebarSelection.outbox)
                }
                Button {
                    openSettings()
                } label: {
                    NCNavigationItem(String(localized: "Mail settings"), icon: MailSymbol.settings.symbol)
                }
                .buttonStyle(.plain)
            }
        }
        .safeAreaInset(edge: .top) {
            Button {
                openComposer(.new(accountId: nil, mailto: nil))
            } label: {
                Label {
                    Text("New message")
                } icon: {
                    MailSymbol.newMessage.view(size: .small, label: .decorative)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, theme.metrics.spacing.standard)
            .padding(.vertical, theme.metrics.spacing.tight)
        }
        .task {
            model.start()
            model.attach(.live(session))
        }
        .onDisappear { model.stop() }
        .sheet(item: $model.infoTarget) { target in
            MailboxInfoView(model: model.infoModel(for: target))
        }
        .sheet(item: $model.moveSource) { source in
            MoveFolderSheet(source: source, model: model)
        }
        .sheet(item: $model.delegationAccount) { account in
            DelegationSheet(account: account, model: model)
        }
        .modifier(SidebarDialogs(model: model, navigation: navigation))
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { navigation.selection }, set: { navigation.select($0) })
    }
}

/// Priority inbox and All inboxes: selections, not folders, so no menu and no drop.
private struct VirtualEntryRow: View {
    let entry: SidebarVirtualEntry

    var body: some View {
        switch entry {
        case .priorityInbox:
            NCNavigationItem(String(localized: "Priority inbox"), icon: MailSymbol.priorityInbox.symbol)
                .tag(SidebarSelection.priorityInbox)
        case .unifiedInbox(let unread):
            NCNavigationItem(String(localized: "All inboxes"), icon: MailSymbol.unifiedInbox.symbol, count: unread)
                .accessibilityElement(children: .combine)
                .tag(SidebarSelection.unifiedInbox)
        }
    }
}

/// One account's rows: the connection-failed or disabled row, then the folders, Favorites
/// and the folder toggle in the layout's order.
private struct AccountSectionContent: View {
    let account: AccountRecord
    @Bindable var model: SidebarStore
    let navigation: NavigationState

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isDisabled(account) {
            Label {
                Text("Provisioned account is disabled")
            } icon: {
                MailSymbol.info.view(size: .small, label: .decorative)
            }
            .foregroundStyle(.secondary)
        } else {
            if model.hasConnectionError(account) {
                ConnectionErrorRow {
                    model.openAccountSettings(account)
                    openSettings()
                }
            }
            ForEach(items) { item in
                switch item {
                case .mailbox(let node):
                    MailboxTreeRowView(node: node, account: account, model: model, navigation: navigation)
                case .favorites(let inboxId):
                    NCNavigationItem(String(localized: "Favorites"), icon: MailSymbol.star.symbol)
                        .tag(SidebarSelection.favorites(inboxId: inboxId))
                case .folderToggle(let expanded):
                    FolderToggleRow(
                        expanded: expanded, subscribedOnly: account.showSubscribedOnly, accountId: account.id,
                        model: model)
                }
            }
        }
    }

    private var items: [SidebarItem] {
        model.layout.accounts.first { $0.accountId == account.id }?.items ?? []
    }
}

private struct ConnectionErrorRow: View {
    let changePassword: () -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Label {
                Text("Connection failed. Please verify your information and try again")
                    .font(.callout)
            } icon: {
                MailSymbol.warning.view(size: .small, label: .text("This account cannot connect"))
            }
            .foregroundStyle(theme.colors.warning.element)
            Button("Change password", action: changePassword)
                .buttonStyle(.tertiary)
                .controlSize(.small)
        }
    }
}

/// "Show all folders" / "Show all subscribed folders" / "Collapse folders". Also a spring
/// target: a message drag hovering here opens the account's folders for the drag (§3.4).
private struct FolderToggleRow: View {
    let expanded: Bool
    let subscribedOnly: Bool
    let accountId: Int64
    let model: SidebarStore

    var body: some View {
        Button {
            model.setShowsAllFolders(!expanded, accountId: accountId)
        } label: {
            Text(title).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .dropDestination(for: MessageDragPayload.self) { _, _ in
            false
        } isTargeted: { targeted in
            if targeted { model.expandForDrag(accountId: accountId) }
        }
    }

    private var title: String {
        if expanded { return String(localized: "Collapse folders") }
        return subscribedOnly ? String(localized: "Show all subscribed folders") : String(localized: "Show all folders")
    }
}

/// One folder, recursively: a plain row for a leaf, a `DisclosureGroup` for anything with
/// children. `NCNavigationItem` has no `children:` slot by design -- its own doc comment says
/// nesting is `DisclosureGroup`'s job, not a hand-rolled copy of it.
private struct MailboxTreeRowView: View {
    let node: MailboxNode
    let account: AccountRecord
    @Bindable var model: SidebarStore
    let navigation: NavigationState

    @State private var isDropTarget = false
    @Environment(\.ncTheme) private var theme

    var body: some View {
        if node.children.isEmpty {
            label.tagged(node)
        } else {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    MailboxTreeRowView(node: child, account: account, model: model, navigation: navigation)
                }
            } label: {
                label
            }
            .tagged(node)
        }
    }

    private var label: some View {
        HStack(spacing: theme.metrics.spacing.tight) {
            NCNavigationItem(displayName, icon: icon, count: ownCount)
            // The web client's "3 (5)": NCNavigationItem takes one count, so the subfolders'
            // total is a second, outlined bubble (library-feedback.md, WS-28).
            if showsCounts, node.descendantUnreadCount > 0 {
                NCCounterBubble(
                    count: node.descendantUnreadCount, role: .outlined,
                    label: .text("\(node.descendantUnreadCount) unread in subfolders"))
            }
        }
        // Unsubscribed mailboxes open but are not mirrored (ADR-0007); the secondary style is
        // the whole difference.
        .foregroundStyle(node.isSubscribed ? .primary : .secondary)
        // `NCNavigationItem` does not combine its children; without this, VoiceOver reads the
        // name and the count as two separate stops.
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let row = node.row {
                FolderMenu(row: row, node: node, account: account, model: model, navigation: navigation)
            }
        }
        .help(syncFailureHelp)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: theme.metrics.radius.small)
                    .fill(theme.colors.primarySurface)
            }
        }
        .dropDestination(for: MessageDragPayload.self) { payloads, _ in
            guard payloads.contains(where: { model.canDrop($0, on: node, accountId: account.id) }) else {
                model.endDrag()
                return false
            }
            Task { _ = await model.drop(payloads, on: node, accountId: account.id) }
            return true
        } isTargeted: { targeted in
            // Only a folder that can take the drop lights up; the payload is not readable
            // until the drop, so the static half of the check (selectable, rights, not
            // Drafts/Sent) decides the highlight and the drop re-checks the rest.
            isDropTarget = targeted && acceptsDrops
            // Spring-loading: hovering a collapsed parent opens it for the drag.
            if targeted, !node.children.isEmpty, !model.isExpanded(accountId: account.id, node: node) {
                model.setExpanded(true, accountId: account.id, node: node)
            }
        }
    }

    private var acceptsDrops: Bool {
        let probe = MessageDragPayload(messageIds: [], sourceMailboxId: -1, accountId: account.id)
        return model.canDrop(probe, on: node, accountId: account.id)
    }

    private var role: String? { node.row?.specialRole?.lowercased() }

    /// Trash shows no count, as on the web.
    private var showsCounts: Bool { role != "trash" }

    private var ownCount: Int { showsCounts ? node.unreadCount : 0 }

    /// Special top-level folders carry the translated name whatever the server calls them.
    private var displayName: String {
        guard node.depth == 0, let role else { return node.displayName }
        switch role {
        case "inbox": return String(localized: "Inbox")
        case "drafts": return String(localized: "Drafts")
        case "sent": return String(localized: "Sent")
        case "trash": return String(localized: "Trash")
        case "junk": return String(localized: "Junk")
        case "archive": return String(localized: "Archive")
        case "all": return String(localized: "All")
        default: return node.displayName
        }
    }

    private var syncFailureHelp: String {
        guard node.row?.hasSyncFailure == true else { return "" }
        return String(localized: "The last sync of this folder failed. Choose Get info for details.")
    }

    private var icon: NCSymbol {
        if let remoteId = node.row?.remoteId, remoteId == account.snoozeMailboxId { return MailSymbol.snooze.symbol }
        switch role {
        case "inbox": return MailSymbol.inbox.symbol
        case "drafts": return MailSymbol.drafts.symbol
        case "sent": return MailSymbol.sent.symbol
        case "archive": return MailSymbol.archive.symbol
        case "junk": return MailSymbol.junk.symbol
        case "trash": return MailSymbol.trash.symbol
        default: return node.row?.isShared == true ? MailSymbol.sharedFolder.symbol : MailSymbol.folder.symbol
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { model.isExpanded(accountId: account.id, node: node) },
            set: { model.setExpanded($0, accountId: account.id, node: node) }
        )
    }
}

extension View {
    /// Tags a row with its mailbox's selection, only when the row can actually be selected --
    /// a `\noselect` or synthetic container never gets a `.tag`, which is what makes selecting
    /// one impossible rather than merely discouraged.
    @ViewBuilder
    fileprivate func tagged(_ node: MailboxNode) -> some View {
        if node.isSelectable, let id = node.row?.id {
            tag(SidebarSelection.mailbox(id))
        } else {
            self
        }
    }
}
