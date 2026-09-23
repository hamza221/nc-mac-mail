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
    /// `⌘P`. The message pane's WebView owns the print operation; this only asks for it.
    var printMessage: (@MainActor () -> Void)?
    /// `⌘F` and `⌘⇧F`. WS-11's, and absent from the menu bar until it is wired.
    var search: (@MainActor (MessageListFilter.Scope) -> Void)?

    private let store: MailStore
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "triage")

    init(store: MailStore) {
        self.store = store
        actions = MessageActions(store: store)
    }

    /// Where the selection can move to: every folder of its account that can hold a message.
    ///
    /// Empty when the selection spans two accounts, because a folder belongs to one of them
    /// and half a move is worse than none. ``isEnabled(_:)`` has already disabled the button
    /// in that case, with the reason in its tooltip.
    func moveDestinations() async -> [MoveDestination] {
        guard actions.selectionAccountIds.count == 1, let accountId = actions.selectionAccountIds.first else {
            return []
        }
        do {
            let records = try await store.mailboxes(accountId: accountId)
            return MailboxTree.build(from: records.map(\.treeRow)).flatMap { $0.destinations() }
        } catch {
            Self.logger.error("could not read move destinations: \(String(describing: error), privacy: .public)")
            return []
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
        case .printMessage: printMessage != nil && listStore?.focusedMessageId != nil
        case .search, .searchAllMail: search != nil
        case .markAllRead: navigation?.selectedMailboxID != nil
        case .previousMessage, .nextMessage: listStore.map { !$0.rows.isEmpty } ?? false
        default: hasSelection && availability(of: action).isAvailable
        }
    }

    /// Runs one action. The single entry point the toolbar, the context menu and the menu bar
    /// share, so a key and a button cannot end up doing different things.
    func perform(_ action: TriageAction) async {
        let selection = selection
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
        case .move:
            // The destination comes from the menu, so there is nothing to do without one.
            Self.logger.error("move performed with no destination")
        }
    }

    func move(to mailboxId: Int64) async {
        await actions.move(selection, to: mailboxId)
    }

    /// Keeps the availability of the three actions that can be refused in step with the
    /// selection. Called from `.task(id:)`, because every answer is a database read.
    func refreshAvailability() async {
        await actions.refreshAvailability(for: selection)
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
