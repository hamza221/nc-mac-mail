// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import OSLog
import Observation

/// What the toolbar, the context menu and the menu bar all read.
///
/// The menu bar is the reason this exists. `Commands` is built in the `App`'s scene body and
/// cannot read a window's `@Environment`, so a menu item has no way to reach the selected
/// rows on its own. One object, handed to the columns and to `MailCommands`, is what lets `A`
/// in the menu bar and the Archive button in the toolbar act on the same selection.
///
/// The three closures are hooks for work this workstream does not own. Each one is nil until
/// the shell fills it in, and a command with no handler is left out of the menu rather than
/// shown dead — `⌘F` in particular, because `.searchable` binds it itself and two bindings
/// mean one that never fires.
@MainActor
@Observable
final class TriageContext {
    let actions: MessageActions

    /// The middle column, for the selection and for the rows that give it an order.
    var listStore: MessageListStore? {
        didSet { actions.list = listStore }
    }
    /// For the threaded-or-flat setting, which decides whether a row is a message or a
    /// conversation, and for the mailbox "Mark all as read" acts on.
    var navigation: NavigationState?

    /// `R`. WS-05's scheduler, through whatever wires it.
    var refresh: (@MainActor () -> Void)?
    /// Whether a refresh is still running, for the Refresh button's spinner. Reads
    /// `AppStatus`, which the engine writes, so observation redraws the button.
    var isRefreshing: (@MainActor () -> Bool)?
    /// `⌘P`. `MessagePrintController` owns the print operation; this only asks for it.
    var printMessage: (@MainActor () -> Void)?
    /// Whether the message pane has a body on screen to print. Reads the controller, which
    /// the pane writes, so observation re-enables the menu item when a body lands. The
    /// focused row is not enough: a message whose body has not arrived prints nothing.
    var canPrintMessage: (@MainActor () -> Bool)?
    /// `⌘F` and `⌘⇧F`. WS-11's, and absent from the menu bar until it is wired.
    var search: (@MainActor (MessageListFilter.Scope) -> Void)?
    /// Opens a composer window. Filled by ``View/triagePresentations(_:)``, which can read
    /// `@Environment(\.openComposer)` where this object cannot.
    var openComposer: (@MainActor (ComposeRequest) -> Void)?

    /// The sheet the main window is showing for a triage action, if any. Set by the menu
    /// bar, the toolbar and the context menu alike; presented by `.triagePresentations`.
    var presentation: TriagePresentation?

    /// The selection's account's quick actions that its mailboxes' ACLs allow (§4.4), for
    /// the Quick Actions submenu. Refreshed with the availability.
    private(set) var quickActions: [RunnableQuickAction] = []

    private let store: MailStore
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "triage")

    init(store: MailStore) {
        self.store = store
        actions = MessageActions(store: store)
    }

    /// Where the selection can move to: every folder of its account that can hold a message
    /// and grants the `i` right (§4.7: "Move lists ACL i folders only").
    ///
    /// Empty when the selection spans two accounts, because a folder belongs to one of them
    /// and half a move is worse than none. ``isEnabled(_:)`` has already disabled the button
    /// in that case, with the reason in its tooltip.
    func moveDestinations() async -> [MoveDestination] {
        guard let tree = await moveTree() else { return [] }
        return tree.nodes.flatMap { $0.destinations() }.filter { tree.pickable.contains($0.id) }
    }

    /// The selection's account's mailbox tree for the move picker, and which of its rows can
    /// take a message: selectable, subscribed and granting `i`.
    func moveTree() async -> MoveTree? {
        guard actions.selectionAccountIds.count == 1, let accountId = actions.selectionAccountIds.first else {
            return nil
        }
        do {
            let records = try await store.mailboxes(accountId: accountId)
            let pickable = Set(
                records.filter { $0.isSelectable && MailboxRights(mailbox: $0).canInsert }.map(\.id))
            return MoveTree(nodes: MailboxTree.build(from: records.map(\.treeRow)), pickable: pickable)
        } catch {
            Self.logger.error("could not read move destinations: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// What every action acts on: the ids the user chose, in the order the rows are drawn.
    ///
    /// Built from `selection` rather than `selectedRows`, which is filtered against the
    /// observation window and therefore misses a row that newly arrived mail has pushed past
    /// the window's end.
    var selection: Selection {
        guard let listStore else { return Selection(messageIds: []) }
        return Selection(
            ids: listStore.selection,
            orderedBy: listStore.rows,
            scope: Selection.scope(for: navigation?.listView ?? .threaded)
        )
    }

    var hasSelection: Bool { !selection.isEmpty }

    func availability(of action: TriageAction) -> TriageAvailability {
        actions.availability[action] ?? .available
    }

    /// Whether the control for `action` should be live: something is selected and the
    /// selection's accounts can do it.
    func isEnabled(_ action: TriageAction) -> Bool {
        switch action {
        case .refresh: refresh != nil
        case .printMessage: printMessage != nil && canPrintMessage?() == true
        case .search, .searchAllMail: search != nil
        case .markAllRead: navigation?.selectedMailboxID != nil
        case .previousMessage, .nextMessage: listStore.map { !$0.rows.isEmpty } ?? false
        case .compose: openComposer != nil
        case .forwardAsAttachment, .editAsNew:
            openComposer != nil && hasSelection && availability(of: action).isAvailable
        default: hasSelection && availability(of: action).isAvailable
        }
    }

    /// Junk's menu title, which follows the web's toggle: "Mark Not Junk" when every selected
    /// message is already junk.
    var junkTitle: String {
        actions.selectionIsJunk ? String(localized: "Mark Not Junk") : TriageAction.junk.title
    }

    /// Runs one action. The single entry point the toolbar, the context menu and the menu bar
    /// share, so a key and a button cannot end up doing different things.
    func perform(_ action: TriageAction) async {
        await perform(action, selection: selection)
    }

    /// The same, on rows that are not the selection — the list's hover buttons act on the
    /// row under the pointer without selecting it (which would open it and mark it read).
    func perform(_ action: TriageAction, on ids: Set<Int64>) async {
        let rows = listStore?.rows ?? []
        await perform(
            action,
            selection: Selection(
                ids: ids, orderedBy: rows, scope: Selection.scope(for: navigation?.listView ?? .threaded))
        )
    }

    private func perform(_ action: TriageAction, selection: Selection) async {
        switch action {
        case .archive: await actions.archive(selection)
        case .delete: await actions.delete(selection)
        case .junk: await actions.junk(selection)
        case .star: await actions.toggleStar(selection)
        case .unread: await actions.toggleUnread(selection)
        case .important: await actions.toggleImportant(selection)
        case .markAllRead:
            guard let mailboxId = navigation?.selectedMailboxID else { return }
            await actions.markAllRead(mailboxId: mailboxId)
        case .refresh: refresh?()
        case .printMessage: printMessage?()
        case .search: search?(.mailbox)
        case .searchAllMail: search?(.allMail)
        case .previousMessage: step(-1)
        case .nextMessage: step(1)
        case .move: presentation = .move(selection)
        case .editTags:
            guard let accountId = await singleAccount(of: selection) else { return }
            presentation = .tags(selection, accountId: accountId)
        case .snooze: presentation = .customSnooze(selection)
        case .unsnooze: await actions.unsnooze(selection)
        case .quickAction:
            // The action comes from the submenu, so there is nothing to do without one.
            Self.logger.error("quick action performed with no action")
        case .compose:
            openComposer?(.new(accountId: await composeAccountId(), mailto: nil))
        case .forwardAsAttachment:
            guard !selection.isEmpty else { return }
            let ids = (try? await actions.expanded(selection).map(\.id)) ?? selection.messageIds
            openComposer?(.forward(messageIds: ids, asAttachment: true))
        case .editAsNew:
            guard let id = selection.messageIds.first else { return }
            openComposer?(.editAsNew(messageId: id))
        }
    }

    func snooze(until date: Date) async {
        await actions.snooze(selection, until: Int64(date.timeIntervalSince1970))
    }

    func snooze(_ selection: Selection, until date: Date) async {
        await actions.snooze(selection, until: Int64(date.timeIntervalSince1970))
    }

    func run(_ quickAction: RunnableQuickAction) async {
        await actions.run(quickAction, on: selection)
    }

    /// The account a new message starts from: the open mailbox's, as the web preselects it;
    /// nil (the composer's default) in the unified views.
    private func composeAccountId() async -> Int64? {
        guard let mailboxId = navigation?.selectedMailboxID else { return nil }
        return try? await store.mailbox(id: mailboxId)?.accountId
    }

    private func singleAccount(of selection: Selection) async -> Int64? {
        let records = (try? await actions.records(for: selection.messageIds)) ?? []
        let accounts = Set(records.map(\.accountId))
        return accounts.count == 1 ? accounts.first : nil
    }

    func move(to mailboxId: Int64) async {
        await actions.move(selection, to: mailboxId)
    }

    func move(_ selection: Selection, to mailboxId: Int64) async {
        await actions.move(selection, to: mailboxId)
    }

    /// Keeps the availability of the actions that can be refused, and the quick actions the
    /// selection allows, in step with the selection. Called from `.task(id:)`, because every
    /// answer is a database read.
    func refreshAvailability() async {
        let selection = selection
        await actions.refreshAvailability(for: selection)
        quickActions = selection.isEmpty ? [] : await actions.quickActions(for: selection)
    }

    /// The rows a right-click landed on. Inside the current selection, the selection stands
    /// and the action covers all of it. Outside it, those rows become the selection, which is
    /// what Mail does and what makes "Archive" archive the row under the pointer.
    func adopt(_ ids: Set<Int64>) {
        guard let listStore, !ids.isEmpty, !ids.isSubset(of: listStore.selection) else { return }
        listStore.selection = ids
    }

    /// `←` and `→`: one row back, one row on, in the list's own order.
    ///
    /// With nothing selected, either key selects the first row, so the keyboard alone can get
    /// into a list it has never clicked.
    private func step(_ offset: Int) {
        guard let listStore else { return }
        let rows = listStore.rows
        guard let first = rows.first else { return }
        guard
            let current = listStore.selection.first,
            let index = rows.firstIndex(where: { $0.id == current })
        else {
            listStore.selection = [first.id]
            return
        }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        listStore.selection = [rows[target].id]
    }
}
