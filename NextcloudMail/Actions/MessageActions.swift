// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// One local `mailbox.id` and the operation that names it, ready for the queue.
///
/// Sendable because an undo registration carries a list of these across the `UndoManager`
/// handler, which is `@Sendable`.
struct QueuedOperation: Sendable, Equatable {
    let accountId: Int64
    let operation: MailOperation
}

/// Where the selection lives, so an action can advance it once the acted-on message leaves
/// the list.
///
/// A protocol rather than a direct reference to `MessageListStore` so that the advance rule
/// can be tested without a live database observation, and so that this workstream owns the
/// contract rather than reaching into another's type.
@MainActor
protocol TriageSelectionSource: AnyObject {
    /// The window of rows on screen, newest first.
    var rows: [MessageRow] { get }
    var selection: Set<Int64> { get set }
}

extension MessageListStore: TriageSelectionSource {}

/// Every triage decision the app can make, as one local transaction and a promise to tell the
/// server.
///
/// **There is no HTTP in this type and no `await` on a response anywhere in it.** Each method
/// builds a ``MailOperation`` and hands it to ``MutationQueue``, which applies the change to
/// the mirror and appends the queue row in a single transaction. The list redraws because the
/// database changed and the observation fired, never because a request answered — which is
/// `CLAUDE.md`'s one invariant at the place a triage button is most tempted to break it.
///
/// Online and offline are the same code path. Offline is `OperationDrainer` having nowhere to
/// send things yet ([offline-queue.md](../../docs/architecture/offline-queue.md)).
@MainActor
@Observable
final class MessageActions {
    /// Why each action cannot run, for the actions that can be unavailable. Refreshed by
    /// ``refreshAvailability(for:)`` when the selection changes, because resolving an
    /// account's archive folder is a database read and a view body cannot await one.
    private(set) var availability: [TriageAction: TriageAvailability] = [:]

    /// The accounts the current selection spans, in id order. The move destination list reads
    /// it: a folder belongs to one account, so there is a list to show only when there is one
    /// account. Refreshed alongside ``availability`` and from the same read.
    private(set) var selectionAccountIds: [Int64] = []

    /// Every selected message is already `$junk`, so Junk reads and acts as "Mark Not Junk"
    /// (§4.4's toggle). Refreshed with ``availability``.
    private(set) var selectionIsJunk = false

    /// Every selected message sits in its account's snooze mailbox, so Snooze gives way to
    /// Unsnooze. Refreshed with ``availability``.
    private(set) var selectionIsSnoozed = false

    /// A sentence the user has to see once, for the outcomes the web reports in a toast:
    /// a quick action whose tag or folder has gone. The presentation host shows it and
    /// clears it.
    var notice: String?

    /// The list whose selection advances after an action that empties a row.
    ///
    /// Weak: the store outlives nothing here, and a column that goes away should not be kept
    /// alive by the object that used to move its cursor.
    weak var list: (any TriageSelectionSource)?

    /// Called after a commit, with the account whose queue grew.
    ///
    /// A closure rather than an `OperationDrainer`, so that `NCMailSync` stays out of this
    /// type's signature and `AccountEngine` remains the app's one owner of a drainer. The
    /// wake is outside the transaction either way — `MutationQueue` wakes its own drainer
    /// after the commit, for exactly the same reason.
    var wakeDrainer: (@MainActor (Int64) -> Void)?

    /// `⌘Z`'s manager.
    ///
    /// The app's own rather than `@Environment(\.undoManager)`: that environment value is
    /// supplied by a document-backed scene and is nil in a plain `WindowGroup`, so relying on
    /// it would make undo work or not work depending on how the shell was assembled
    /// ([ADR-0051](../../docs/decisions/0051-triage-owns-its-undo-manager.md)).
    let undoManager = UndoManager()

    // Internal rather than private from here down: `MessageActions+V2.swift` builds the v2
    // actions (tags, snooze, spam, quick actions) on the same machinery.
    let store: MailStore
    /// One per account. `MutationQueue` is a thin actor over the store, so this costs nothing
    /// and saves resolving the account on every keystroke.
    private var queues: [Int64: MutationQueue] = [:]

    /// Identifiers and counts only. A subject or an address in this log is the same leak as
    /// one in a crash report.
    static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "triage")

    init(store: MailStore) {
        self.store = store
    }

    // MARK: - The actions

    /// To the archive folder of the account that owns each message — **not** of the account
    /// the sidebar has selected. A selection spanning two accounts produces one operation per
    /// account, each aimed at its own folder.
    func archive(_ selection: Selection) async {
        await moveToRole(selection, role: .archive, action: .archive)
    }

    /// To trash, or an erase when the message is already in trash. The queue decides which,
    /// per message, because a mixed selection can be both.
    func delete(_ selection: Selection) async {
        await act(.delete, on: selection) { context in
            let trash = try await context.queue.localMailboxId(for: .trash, accountId: context.accountId)
            // A message already in trash is erased rather than moved, and nothing restores an
            // erased row. Those are left out of the inverse instead of being restored into a
            // folder they are no longer in.
            let restorable = context.expanded.filter { $0.mailboxId != trash && trash != nil }
            switch context.selection.scope {
            case .messages:
                return Work(
                    operations: [
                        QueuedOperation(
                            accountId: context.accountId, operation: .delete(messageIds: context.messageIds))
                    ],
                    undo: Self.moveBack(restorable)
                )
            case .threads:
                return Work(
                    operations: context.threadRoots.map {
                        QueuedOperation(accountId: context.accountId, operation: .deleteThread(rootId: $0))
                    },
                    undo: Self.moveBack(restorable)
                )
            }
        }
    }

    /// To a folder the user picked. The destination belongs to one account, so a selection
    /// spanning several is refused rather than half-applied — see
    /// ``refreshAvailability(for:)``.
    func move(_ selection: Selection, to mailboxId: Int64) async {
        guard let mailbox = try? await store.mailbox(id: mailboxId) else {
            Self.logger.error("move to a mailbox that is not mirrored: \(mailboxId, privacy: .public)")
            return
        }
        await act(.move, on: selection) { context in
            guard context.accountId == mailbox.accountId else {
                Self.logger.error(
                    """
                    refusing to move account \(context.accountId, privacy: .public)'s messages into \
                    account \(mailbox.accountId, privacy: .public)'s folder
                    """
                )
                return nil
            }
            switch context.selection.scope {
            case .messages:
                return Work(
                    operations: [
                        QueuedOperation(
                            accountId: context.accountId,
                            operation: .move(messageIds: context.messageIds, destinationMailboxId: mailboxId)
                        )
                    ],
                    undo: Self.moveBack(context.records)
                )
            case .threads:
                return Work(
                    operations: context.threadRoots.map {
                        QueuedOperation(
                            accountId: context.accountId,
                            operation: .moveThread(rootId: $0, destinationMailboxId: mailboxId)
                        )
                    },
                    undo: Self.moveBack(context.records)
                )
            }
        }
    }

    func toggleStar(_ selection: Selection) async {
        await toggle(.star, key: "flagged", on: selection, reading: \.isFlagged)
    }

    /// `seen` rather than an "unread" column, so the rule is the same as the other two
    /// toggles: if any message lacks the flag, set it everywhere; otherwise clear it. `U` on
    /// an unread message marks it read, `U` on a read one marks it unread, and a mixed
    /// selection is made read.
    func toggleUnread(_ selection: Selection) async {
        await toggle(.unread, key: "seen", on: selection, reading: \.isSeen)
    }

    func toggleImportant(_ selection: Selection) async {
        await toggle(.important, key: "important", on: selection, reading: \.isImportant)
    }

    /// Every unread message in one mailbox, in one transaction.
    ///
    /// The server has no mark-all-read route — [api-payloads.md](../../docs/reference/api-payloads.md#mutations)
    /// lists six mutations and none of them is this one — so it is one `setFlags` per unread
    /// message, and a mailbox with a thousand unread messages is a thousand queue rows. The
    /// local write is one transaction; the drain is a thousand round trips.
    func markAllRead(mailboxId: Int64) async {
        do {
            guard let mailbox = try await store.mailbox(id: mailboxId) else { return }
            let unread = try await unreadMessageIds(mailboxId: mailboxId)
            guard !unread.isEmpty else { return }
            let work = Work(
                operations: [
                    QueuedOperation(
                        accountId: mailbox.accountId,
                        operation: .setFlags(messageIds: unread, flags: ["seen": true])
                    )
                ],
                undo: [
                    QueuedOperation(
                        accountId: mailbox.accountId,
                        operation: .setFlags(messageIds: unread, flags: ["seen": false])
                    )
                ]
            )
            await commit(work, action: .markAllRead, advancingPast: [])
        } catch {
            Self.logger.error(
                "mark-all-read failed for mailbox \(mailboxId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Opening a message reads it, after the delay the reader chose in Settings.
    ///
    /// Called from `.task(id:)` on the focused message, so moving to another message cancels
    /// the sleep and "after 5 seconds" means five seconds *on this message*. Not undoable and
    /// no selection advance: opening is not a triage decision, and `⌘Z` after clicking a
    /// message should undo the last thing the reader did, not the click.
    func messageOpened(_ messageId: Int64) async {
        let raw = (try? await store.metaValue(forKey: MarkAsReadDelay.metaKey)) ?? nil
        switch MarkAsReadDelay(metaValue: raw) {
        case .manually:
            return
        case .immediately:
            break
        case .after(let seconds):
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        }
        do {
            guard let record = try await store.message(id: messageId), !record.isSeen else { return }
            await apply([
                QueuedOperation(
                    accountId: record.accountId,
                    operation: .setFlags(messageIds: [record.id], flags: ["seen": true])
                )
            ])
        } catch {
            Self.logger.error(
                "mark-read on open failed for message \(messageId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// "Always show images from this sender", for every message from them in the account.
    ///
    /// Queued like any triage action so it survives being offline, and applied to every
    /// stored body from the sender at once. Not undoable: it is a reading preference, not a
    /// triage decision, and `⌘Z` should not reach past the reader's last action for it.
    func trustSender(email: String, accountId: Int64) async {
        await apply([QueuedOperation(accountId: accountId, operation: .trustSender(email: email, trusted: true))])
    }

    // MARK: - Availability

    /// Works out which actions this selection can run, and the sentence to show when one
    /// cannot.
    ///
    /// Called from `.task(id:)` on the selection. The answer is stored rather than computed
    /// in a view body because every one of these questions is a database read.
    func refreshAvailability(for selection: Selection) async {
        guard !selection.isEmpty else {
            availability = [:]
            selectionAccountIds = []
            selectionIsJunk = false
            selectionIsSnoozed = false
            return
        }
        var fresh: [TriageAction: TriageAvailability] = [:]
        do {
            let records = try await self.records(for: selection.messageIds)
            let accountIds = Set(records.map(\.accountId)).sorted()
            selectionAccountIds = accountIds
            fresh[.archive] = try await availability(of: .archive, accountIds: accountIds)
            fresh[.junk] = try await availability(of: .junk, accountIds: accountIds)
            fresh[.move] =
                accountIds.count > 1
                ? .unavailable(String(localized: "Messages from more than one account cannot move to one folder."))
                : .available
            selectionIsJunk = !records.isEmpty && records.allSatisfy(\.isJunk)
            selectionIsSnoozed = try await allSnoozed(records)
            fresh.merge(v2Availability(records: records, accountIds: accountIds)) { _, new in new }
        } catch {
            Self.logger.error("could not resolve availability: \(String(describing: error), privacy: .public)")
        }
        availability = fresh
    }

    private func availability(of special: SpecialMailbox, accountIds: [Int64]) async throws -> TriageAvailability {
        var missing: [String] = []
        for accountId in accountIds {
            let resolved = try await queue(for: accountId).localMailboxId(for: special, accountId: accountId)
            guard resolved == nil else { continue }
            let name = try await store.account(id: accountId)?.name ?? String(localized: "This account")
            missing.append(name)
        }
        guard !missing.isEmpty else { return .available }
        let folder = special == .archive ? String(localized: "Archive") : String(localized: "Junk")
        if missing.count == 1, let only = missing.first {
            return .unavailable(String(localized: "\(only) has no \(folder) folder on the server."))
        }
        return .unavailable(
            String(localized: "\(missing.count) of the selected accounts have no \(folder) folder on the server.")
        )
    }

    // MARK: - Undo

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: - Advancing the selection

    /// The row to select once every id in `acted` has left the list.
    ///
    /// The next row in sort order, which is the one below since the list is newest first; the
    /// row above when the acted-on rows were at the end; nothing when they were the whole
    /// list. Computed from the rows as they are **now**, before the observation delivers the
    /// list without them, so the answer does not depend on when that delivery lands.
    static func nextSelection(after acted: Set<Int64>, in rows: [MessageRow]) -> Int64? {
        guard let last = rows.lastIndex(where: { acted.contains($0.id) }) else { return nil }
        if let below = rows[(last + 1)...].first(where: { !acted.contains($0.id) }) { return below.id }
        if let above = rows[..<last].last(where: { !acted.contains($0.id) }) { return above.id }
        return nil
    }

    // MARK: - Machinery

    /// Everything an action needs to build its operations, resolved once per account.
    struct Context {
        let accountId: Int64
        let queue: MutationQueue
        let selection: Selection
        /// The selected messages of this account, in selection order.
        let records: [MessageRecord]
        /// Every message the action really touches: the selection, or every member of every
        /// selected thread.
        let expanded: [MessageRecord]

        var messageIds: [Int64] { records.map(\.id) }
        var expandedIds: [Int64] { expanded.map(\.id) }
        /// Distinct thread roots, in selection order.
        var threadRoots: [String] {
            var seen: Set<String> = []
            return records.compactMap { record in
                guard let root = record.threadRootId, seen.insert(root).inserted else { return nil }
                return root
            }
        }
    }

    /// What one account's share of an action turns into.
    struct Work {
        var operations: [QueuedOperation]
        /// The operations that put it back, in the order they must be applied.
        var undo: [QueuedOperation]
    }

    /// Runs `build` once per account in the selection and commits everything it produced.
    ///
    /// `build` returning nil means this account cannot do it — no archive folder, a
    /// destination belonging to someone else — and the other accounts still go through. A
    /// mixed selection is the case the brief calls out and the one an early return would get
    /// wrong.
    func act(
        _ action: TriageAction,
        on selection: Selection,
        removesFromList: Bool? = nil,
        _ build: (Context) async throws -> Work?
    ) async {
        guard !selection.isEmpty else { return }
        do {
            var combined = Work(operations: [], undo: [])
            for context in try await contexts(for: selection) {
                guard let work = try await build(context) else {
                    Self.logger.info(
                        """
                        \(action.rawValue, privacy: .public) unavailable for account \
                        \(context.accountId, privacy: .public)
                        """
                    )
                    continue
                }
                combined.operations.append(contentsOf: work.operations)
                combined.undo.append(contentsOf: work.undo)
            }
            await commit(
                combined, action: action, advancingPast: Set(selection.messageIds), removesFromList: removesFromList)
        } catch {
            Self.logger.error(
                "\(action.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The shared body of the three toggles.
    ///
    /// One rule for all of them: if any message lacks the flag, set it on every message;
    /// otherwise clear it on every message. The payload is absolute state, never a toggle,
    /// which is what makes replaying a queued operation after an ambiguous timeout safe.
    private func toggle(
        _ action: TriageAction,
        key: String,
        on selection: Selection,
        reading flag: KeyPath<MessageRecord, Bool>
    ) async {
        await act(action, on: selection) { context in
            let messages = context.expanded
            guard !messages.isEmpty else { return nil }
            let value = messages.contains { !$0[keyPath: flag] }
            let ids = messages.map(\.id)
            // The inverse restores each message's own previous value, so un-starring a mixed
            // selection and undoing it gives back the mix rather than one blanket state.
            let restore = Dictionary(grouping: messages, by: { $0[keyPath: flag] })
            return Work(
                operations: [
                    QueuedOperation(
                        accountId: context.accountId, operation: .setFlags(messageIds: ids, flags: [key: value]))
                ],
                undo: restore.keys.sorted { !$0 && $1 }.compactMap { previous in
                    guard let group = restore[previous] else { return nil }
                    return QueuedOperation(
                        accountId: context.accountId,
                        operation: .setFlags(messageIds: group.map(\.id), flags: [key: previous])
                    )
                }
            )
        }
    }

    /// To one of the mailboxes an account names by role. Archive is a `move`, never an
    /// operation kind of its own, and the id is resolved from the account that owns the
    /// message.
    private func moveToRole(_ selection: Selection, role: SpecialMailbox, action: TriageAction) async {
        await act(action, on: selection) { context in
            guard let destination = try await context.queue.localMailboxId(for: role, accountId: context.accountId)
            else {
                return nil
            }
            switch context.selection.scope {
            case .messages:
                return Work(
                    operations: [
                        QueuedOperation(
                            accountId: context.accountId,
                            operation: .move(messageIds: context.messageIds, destinationMailboxId: destination)
                        )
                    ],
                    undo: Self.moveBack(context.records)
                )
            case .threads:
                return Work(
                    operations: context.threadRoots.map {
                        QueuedOperation(
                            accountId: context.accountId,
                            operation: .moveThread(rootId: $0, destinationMailboxId: destination)
                        )
                    },
                    undo: Self.moveBack(context.expanded)
                )
            }
        }
    }

    /// Enqueues every operation, registers the undo, and advances the selection.
    func commit(
        _ work: Work, action: TriageAction, advancingPast acted: Set<Int64>, removesFromList: Bool? = nil
    ) async {
        guard !work.operations.isEmpty else { return }
        let removes = removesFromList ?? action.removesFromList
        let next = removes ? list.flatMap { Self.nextSelection(after: acted, in: $0.rows) } : nil

        await apply(work.operations)
        register(undo: work.undo, redo: work.operations, name: action.undoName)

        if removes, let list {
            list.selection = next.map { [$0] } ?? []
        }
    }

    func apply(_ operations: [QueuedOperation]) async {
        for item in operations {
            do {
                try await queue(for: item.accountId).perform(item.operation, accountId: item.accountId)
                wakeDrainer?(item.accountId)
            } catch {
                Self.logger.error(
                    """
                    queueing failed for account \(item.accountId, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
        }
    }

    /// Puts `inverse` on the undo stack, and arranges for undoing it to put `forward` on the
    /// redo stack.
    ///
    /// The re-registration is made **synchronously**, inside the handler `UndoManager` calls
    /// during `undo()`, which is what lands it on the redo stack rather than back on the undo
    /// one. The database work is a `Task` after it, because the registration only has to
    /// describe what redo would do and that is already known.
    func register(undo inverse: [QueuedOperation], redo forward: [QueuedOperation], name: String) {
        guard !inverse.isEmpty else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: self) { target in
            // `UndoManager` on macOS is driven from the Edit menu and from this app's own
            // command menu, both of which are the main thread, and `MessageActions` is
            // `@MainActor`, so the handler is already on it.
            MainActor.assumeIsolated {
                target.register(undo: forward, redo: inverse, name: name)
                Task { await target.apply(inverse) }
            }
        }
    }

    /// The operations that put each message back where it was, one per origin mailbox.
    ///
    /// A move of ten messages out of three folders has to return each one to its own, which is
    /// why this groups rather than remembering a single destination. Messages the action
    /// erased have nothing to go back to and are not represented here — a `delete` of a
    /// message already in trash removes the row, and no operation restores it.
    static func moveBack(_ records: [MessageRecord]) -> [QueuedOperation] {
        Dictionary(grouping: records) { MailboxKey(accountId: $0.accountId, mailboxId: $0.mailboxId) }
            .sorted { $0.key.mailboxId < $1.key.mailboxId }
            .map { key, group in
                QueuedOperation(
                    accountId: key.accountId,
                    operation: .move(messageIds: group.map(\.id), destinationMailboxId: key.mailboxId)
                )
            }
    }

    private struct MailboxKey: Hashable {
        let accountId: Int64
        let mailboxId: Int64
    }

    // MARK: - Reading the mirror

    func queue(for accountId: Int64) -> MutationQueue {
        if let existing = queues[accountId] { return existing }
        // No drainer: `wakeDrainer` does that, which keeps `OperationDrainer` out of this
        // type's signature and `AccountEngine` the one owner of one.
        let queue = MutationQueue(store: store)
        queues[accountId] = queue
        return queue
    }

    /// The selection, grouped by the account that owns each message, in selection order.
    func contexts(for selection: Selection) async throws -> [Context] {
        let records = try await self.records(for: selection.messageIds)
        var order: [Int64] = []
        var byAccount: [Int64: [MessageRecord]] = [:]
        for record in records {
            if byAccount[record.accountId] == nil { order.append(record.accountId) }
            byAccount[record.accountId, default: []].append(record)
        }

        var contexts: [Context] = []
        for accountId in order {
            guard let owned = byAccount[accountId] else { continue }
            let expanded: [MessageRecord]
            switch selection.scope {
            case .messages:
                expanded = owned
            case .threads:
                expanded = try await threadMembers(of: owned, accountId: accountId)
            }
            contexts.append(
                Context(
                    accountId: accountId,
                    queue: queue(for: accountId),
                    selection: selection,
                    records: owned,
                    expanded: expanded
                )
            )
        }
        return contexts
    }

    /// Reads each id that the mirror still has. One the mirror has lost is skipped: there is
    /// no local change to make and a request would only earn a 403 for a stale id.
    func records(for ids: [Int64]) async throws -> [MessageRecord] {
        var records: [MessageRecord] = []
        records.reserveCapacity(ids.count)
        for id in ids {
            guard let record = try await store.message(id: id) else { continue }
            records.append(record)
        }
        return records
    }

    /// Every message of every thread the selection touches, without duplicates. A message with
    /// no thread root is a thread of one.
    private func threadMembers(of records: [MessageRecord], accountId: Int64) async throws -> [MessageRecord] {
        var seen: Set<Int64> = []
        var members: [MessageRecord] = []
        for record in records {
            guard let root = record.threadRootId else {
                if seen.insert(record.id).inserted { members.append(record) }
                continue
            }
            for member in try await store.threadMessages(accountId: accountId, rootId: root)
            where seen.insert(member.id).inserted {
                members.append(member)
            }
        }
        return members
    }

    /// Every unread message in a mailbox, read a window at a time.
    ///
    /// The flat view, because the threaded one returns one row per thread and the replies
    /// under it would stay unread. There is no `unreadMessageIds(mailboxId:)` on `MailStore`,
    /// so this walks the same windowed reader the list uses and filters — see this
    /// workstream's report for the measurement and the request.
    private func unreadMessageIds(mailboxId: Int64) async throws -> [Int64] {
        var unread: [Int64] = []
        var offset = 0
        let page = 1000
        while true {
            let rows = try await store.messages(mailboxId: mailboxId, view: .flat, range: offset..<(offset + page))
            unread.append(contentsOf: rows.lazy.filter { !$0.isSeen }.map(\.id))
            guard rows.count == page else { break }
            offset += page
        }
        return unread
    }
}
