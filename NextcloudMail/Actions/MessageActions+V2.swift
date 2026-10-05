// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync

/// Triage v2 (WS-31): spam, tags, snooze, quick actions.
///
/// The same contract as the rest of ``MessageActions``: every method builds `MailOperation`s
/// and hands them to the queue, which writes the mirror and the promise in one transaction.
/// No HTTP, no awaiting a response, offline and online are one path.
extension MessageActions {
    // MARK: - Spam (§4.4)

    /// "Mark as spam" / "Mark not spam", as the web toggles them.
    ///
    /// When every selected message is already `$junk`, this is *not spam*: `junk=false`,
    /// `notjunk=true`, and the ones in the Junk folder go back to the Inbox. Otherwise it is
    /// *spam*: flags then move to Junk. Both mark the messages read and clear Important, which
    /// is what the web's `onToggleJunkThread` does to every envelope it touches.
    ///
    /// There is no junk-thread route, so a thread is junked by expanding it to its members.
    func junk(_ selection: Selection) async {
        let records = (try? await records(for: selection.messageIds)) ?? []
        let notSpam = !records.isEmpty && records.allSatisfy(\.isJunk)
        await act(.junk, on: selection) { context in
            notSpam ? try await self.notSpamWork(context) : try await self.spamWork(context)
        }
    }

    func spamWork(_ context: Context) async throws -> Work? {
        guard let destination = try await context.queue.localMailboxId(for: .junk, accountId: context.accountId)
        else { return nil }
        let messages = context.expanded
        let ids = messages.map(\.id)
        var operations = Self.readAndUnimportant(messages, accountId: context.accountId)
        operations.append(
            QueuedOperation(accountId: context.accountId, operation: .junk(messageIds: ids, junkMailboxId: destination))
        )
        // Undoing spam says *not junk* rather than restoring "unclassified" — v1's rule
        // (TriageUndoTests): the user just told us the message is wanted, and the classifier
        // should hear it. Read and Important go back to each message's own value.
        var undo = [
            QueuedOperation(
                accountId: context.accountId,
                operation: .setFlags(messageIds: ids, flags: ["junk": false, "notjunk": true]))
        ]
        undo += Self.restoreFlags(
            messages, accountId: context.accountId, keys: ["seen": \.isSeen, "important": \.isImportant])
        undo.append(contentsOf: Self.moveBack(messages.filter { $0.mailboxId != destination }))
        return Work(operations: operations, undo: undo)
    }

    func notSpamWork(_ context: Context) async throws -> Work? {
        let messages = context.expanded
        let ids = messages.map(\.id)
        var flags: [String: Bool] = ["junk": false, "notjunk": true]
        if messages.contains(where: { !$0.isSeen }) { flags["seen"] = true }
        if messages.contains(where: \.isImportant) { flags["important"] = false }
        var operations = [
            QueuedOperation(accountId: context.accountId, operation: .setFlags(messageIds: ids, flags: flags))
        ]
        let junk = try await context.queue.localMailboxId(for: .junk, accountId: context.accountId)
        let inJunk = messages.filter { junk != nil && $0.mailboxId == junk }
        if !inJunk.isEmpty, let inbox = try await inboxId(accountId: context.accountId) {
            operations.append(
                QueuedOperation(
                    accountId: context.accountId,
                    operation: .move(messageIds: inJunk.map(\.id), destinationMailboxId: inbox)
                )
            )
        }
        var undo = Self.restoreFlags(
            messages, accountId: context.accountId,
            keys: ["junk": \.isJunk, "notjunk": \.isNotJunk, "seen": \.isSeen, "important": \.isImportant])
        if operations.count > 1 { undo.append(contentsOf: Self.moveBack(inJunk)) }
        return Work(operations: operations, undo: undo)
    }

    /// Read, and not important, for the messages that are not already.
    private static func readAndUnimportant(_ messages: [MessageRecord], accountId: Int64) -> [QueuedOperation] {
        var flags: [String: Bool] = [:]
        if messages.contains(where: { !$0.isSeen }) { flags["seen"] = true }
        if messages.contains(where: \.isImportant) { flags["important"] = false }
        guard !flags.isEmpty else { return [] }
        return [
            QueuedOperation(accountId: accountId, operation: .setFlags(messageIds: messages.map(\.id), flags: flags))
        ]
    }

    /// Operations that put each message's named flags back to what they were, one per
    /// distinct combination, so a mixed selection gets its mix back.
    static func restoreFlags(
        _ messages: [MessageRecord], accountId: Int64, keys: [String: KeyPath<MessageRecord, Bool>]
    ) -> [QueuedOperation] {
        let ordered = keys.sorted { $0.key < $1.key }
        var groups: [[Bool]: [Int64]] = [:]
        var order: [[Bool]] = []
        for message in messages {
            let values = ordered.map { message[keyPath: $0.value] }
            if groups[values] == nil { order.append(values) }
            groups[values, default: []].append(message.id)
        }
        return order.compactMap { values in
            guard let ids = groups[values] else { return nil }
            var flags: [String: Bool] = [:]
            for (index, key) in ordered.enumerated() { flags[key.key] = values[index] }
            return QueuedOperation(accountId: accountId, operation: .setFlags(messageIds: ids, flags: flags))
        }
    }

    // MARK: - Tags (§4.8)

    /// Sets `tag` on every message of the selection, or — when every one already has it —
    /// unsets it everywhere. The modal's Set/Unset button.
    ///
    /// Undo restores each message's own previous state for that label.
    func toggleTag(_ tag: TagRecord, on selection: Selection) async {
        do {
            let messages = try await expanded(selection).filter { $0.accountId == tag.accountId }
            let labels = try await store.messageTagLabels(messageIds: messages.map(\.id))
            let present = !messages.allSatisfy { labels[$0.id]?.contains(tag.imapLabel) == true }
            await setTag(tag, present: present, on: messages, labels: labels)
        } catch {
            Self.logger.error("tag toggle failed: \(String(describing: error), privacy: .public)")
        }
    }

    func setTag(_ tag: TagRecord, present: Bool, on selection: Selection) async {
        do {
            let messages = try await expanded(selection).filter { $0.accountId == tag.accountId }
            let labels = try await store.messageTagLabels(messageIds: messages.map(\.id))
            await setTag(tag, present: present, on: messages, labels: labels)
        } catch {
            Self.logger.error("tag change failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func setTag(
        _ tag: TagRecord, present: Bool, on messages: [MessageRecord], labels: [Int64: [String]]
    )
        async
    {
        let label = tag.imapLabel
        let had = messages.filter { labels[$0.id]?.contains(label) == true }.map(\.id)
        let lacked = messages.filter { labels[$0.id]?.contains(label) != true }.map(\.id)
        let changing = present ? lacked : had
        guard !changing.isEmpty else { return }
        let operation: MailOperation =
            present
            ? .setTag(messageIds: changing, imapLabel: label) : .unsetTag(messageIds: changing, imapLabel: label)
        let inverse: MailOperation =
            present
            ? .unsetTag(messageIds: changing, imapLabel: label) : .setTag(messageIds: changing, imapLabel: label)
        await commit(
            Work(
                operations: [QueuedOperation(accountId: tag.accountId, operation: operation)],
                undo: [QueuedOperation(accountId: tag.accountId, operation: inverse)]
            ),
            action: .editTags,
            advancingPast: []
        )
    }

    /// The tags set on *every* message of the selection, for the modal's Set/Unset state.
    func labelsOnAll(_ selection: Selection) async -> Set<String> {
        guard
            let messages = try? await expanded(selection), !messages.isEmpty,
            let labels = try? await store.messageTagLabels(messageIds: messages.map(\.id))
        else { return [] }
        return messages.dropFirst().reduce(Set(labels[messages[0].id] ?? [])) { common, message in
            common.intersection(labels[message.id] ?? [])
        }
    }

    /// A new tag, offline-safe: the queue gives it a placeholder id and label (ADR-0081),
    /// and it may be set on messages before the server has heard of it. Not undoable — the
    /// web has no undo for it either.
    func createTag(accountId: Int64, displayName: String, color: String) async {
        await apply([
            QueuedOperation(
                accountId: accountId,
                operation: .createTag(displayName: displayName.trimmingCharacters(in: .whitespaces), color: color))
        ])
    }

    func updateTag(_ tag: TagRecord, displayName: String, color: String) async {
        await apply([
            QueuedOperation(
                accountId: tag.accountId,
                operation: .updateTag(
                    tagRemoteId: tag.remoteId, displayName: displayName.trimmingCharacters(in: .whitespaces),
                    color: color))
        ])
    }

    /// Removes the tag from every message as well. Confirmed in the modal, never undone.
    func deleteTag(_ tag: TagRecord) async {
        await apply([QueuedOperation(accountId: tag.accountId, operation: .deleteTag(tagRemoteId: tag.remoteId))])
    }

    // MARK: - Snooze (§4.4)

    /// The snooze folder's name when this client creates one, as the web's
    /// `createAndSetSnoozeMailbox` names it.
    static let snoozedMailboxName = "Snoozed"

    /// Snoozes the selection until `until` (Unix seconds).
    ///
    /// An account with no snooze mailbox gets one first, as the web does on first use: a
    /// mailbox called "Snoozed" is reused if there is one, otherwise `createMailbox` is
    /// queued; then `patchAccount(snoozeMailboxId:)`, then the snooze. All three are queue
    /// rows, so it works offline — the mailbox is a placeholder row until the drain swaps
    /// its id (ADR-0081). Undo unsnoozes; the folder stays.
    func snooze(_ selection: Selection, until: Int64) async {
        await act(.snooze, on: selection) { context in
            guard try await self.ensureSnoozeMailbox(accountId: context.accountId) != nil else { return nil }
            switch context.selection.scope {
            case .messages:
                return Work(
                    operations: [
                        QueuedOperation(
                            accountId: context.accountId,
                            operation: .snooze(messageIds: context.messageIds, until: until))
                    ],
                    undo: [
                        QueuedOperation(
                            accountId: context.accountId, operation: .unsnooze(messageIds: context.messageIds))
                    ]
                )
            case .threads:
                let roots = context.threadRoots
                return Work(
                    operations: roots.map {
                        QueuedOperation(
                            accountId: context.accountId, operation: .snoozeThread(rootId: $0, until: until))
                    },
                    undo: roots.map {
                        QueuedOperation(accountId: context.accountId, operation: .unsnoozeThread(rootId: $0))
                    }
                )
            }
        }
    }

    /// Back to where it came from, as the server decides (the source folder, else Inbox).
    /// Not undoable: the web offers none, and the time it was snoozed until is gone.
    func unsnooze(_ selection: Selection) async {
        guard !selection.isEmpty else { return }
        do {
            let contexts = try await contexts(for: selection)
            var operations: [QueuedOperation] = []
            for context in contexts {
                switch selection.scope {
                case .messages:
                    operations.append(
                        QueuedOperation(
                            accountId: context.accountId, operation: .unsnooze(messageIds: context.messageIds))
                    )
                case .threads:
                    operations += context.threadRoots.map {
                        QueuedOperation(accountId: context.accountId, operation: .unsnoozeThread(rootId: $0))
                    }
                }
            }
            await commit(
                Work(operations: operations, undo: []), action: .unsnooze, advancingPast: Set(selection.messageIds))
        } catch {
            Self.logger.error("unsnooze failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The account's snooze mailbox, local id, creating and configuring it when there is
    /// none. Nil only when the queue refused the creation.
    @discardableResult
    func ensureSnoozeMailbox(accountId: Int64) async throws -> Int64? {
        if let existing = try await snoozeMailboxId(accountId: accountId) { return existing }
        var mailboxes = try await store.mailboxes(accountId: accountId)
        var target = mailboxes.first { $0.name == Self.snoozedMailboxName }
        if target == nil {
            await apply([
                QueuedOperation(accountId: accountId, operation: .createMailbox(name: Self.snoozedMailboxName))
            ])
            mailboxes = try await store.mailboxes(accountId: accountId)
            target = mailboxes.first { $0.name == Self.snoozedMailboxName }
        }
        guard let target else {
            Self.logger.error("could not create the snooze mailbox for account \(accountId, privacy: .public)")
            return nil
        }
        await apply([
            QueuedOperation(accountId: accountId, operation: .patchAccount(AccountPatch(snoozeMailboxId: target.id)))
        ])
        return target.id
    }

    /// `account.snoozeMailboxId` is the server's number (or a placeholder), like its siblings;
    /// this is the mirror's.
    func snoozeMailboxId(accountId: Int64) async throws -> Int64? {
        guard let remote = try await store.account(id: accountId)?.snoozeMailboxId else { return nil }
        return try await store.mailboxes(accountId: accountId).first { $0.remoteId == remote }?.id
    }

    func allSnoozed(_ records: [MessageRecord]) async throws -> Bool {
        guard !records.isEmpty else { return false }
        var snoozeIds: [Int64: Int64?] = [:]
        for record in records {
            if snoozeIds[record.accountId] == nil {
                snoozeIds[record.accountId] = .some(try await snoozeMailboxId(accountId: record.accountId))
            }
            guard let id = snoozeIds[record.accountId] ?? nil, record.mailboxId == id else { return false }
        }
        return true
    }

    // MARK: - Quick actions (§4.4, §8.7)

    /// One account's quick actions that the selection's source mailboxes allow, with their
    /// steps in order. The web's `filteredQuickActions`.
    func quickActions(for selection: Selection) async -> [RunnableQuickAction] {
        guard
            let records = try? await records(for: selection.messageIds),
            let accountId = records.first?.accountId,
            records.allSatisfy({ $0.accountId == accountId })
        else { return [] }
        var rights = MailboxRights.unrestricted
        var combined: String?
        for mailboxId in Set(records.map(\.mailboxId)) {
            guard let mailbox = try? await store.mailbox(id: mailboxId) else { continue }
            let acls = MailboxRights(mailbox: mailbox).acls
            // Several source folders: the rights all of them grant.
            if let acls { combined = combined.map { String($0.filter(acls.contains)) } ?? acls }
        }
        if let combined { rights = MailboxRights(acls: combined) }

        var runnable: [RunnableQuickAction] = []
        for action in (try? await store.quickActions(accountId: accountId)) ?? [] {
            guard let localId = action.id else { continue }
            let steps = ((try? await store.quickActionSteps(quickActionId: localId)) ?? []).sorted {
                $0.position < $1.position
            }
            guard !steps.isEmpty, steps.allSatisfy({ QuickActionStep.permitted($0.name, rights: rights) }) else {
                continue
            }
            runnable.append(RunnableQuickAction(id: localId, accountId: accountId, name: action.name, steps: steps))
        }
        return runnable
    }

    /// Runs every step, in order, as one undoable change.
    ///
    /// Each step is built from the state the previous ones leave, so "mark read, then move"
    /// moves the message it just marked. A tag or folder the step names that is no longer in
    /// the mirror skips that step with the web's warning, and the rest still run.
    func run(_ quickAction: RunnableQuickAction, on selection: Selection) async {
        guard !selection.isEmpty else { return }
        var undoSteps: [[QueuedOperation]] = []
        var forward: [QueuedOperation] = []
        var removes = false
        var warnings: [String] = []
        do {
            for step in quickAction.steps {
                guard
                    let context = try await contexts(for: selection).first(where: {
                        $0.accountId == quickAction.accountId
                    })
                else { break }
                guard let work = try await quickActionWork(step, context: context, warnings: &warnings) else {
                    continue
                }
                await apply(work.operations)
                forward += work.operations
                undoSteps.append(work.undo)
                if QuickActionStep.isTerminal(step.name) { removes = true }
            }
        } catch {
            Self.logger.error("quick action failed: \(String(describing: error), privacy: .public)")
            notice = String(localized: "Could not execute quick action")
        }
        // The last step's inverse runs first.
        register(undo: undoSteps.reversed().flatMap { $0 }, redo: forward, name: quickAction.name)
        if removes, let list {
            let next = Self.nextSelection(after: Set(selection.messageIds), in: list.rows)
            list.selection = next.map { [$0] } ?? []
        }
        if let warning = warnings.first { notice = warning }
    }

    private func quickActionWork(
        _ step: QuickActionStepRecord, context: Context, warnings: inout [String]
    ) async throws -> Work? {
        let accountId = context.accountId
        let messages = context.expanded
        switch step.name {
        case QuickActionStep.markAsSpam:
            return messages.allSatisfy(\.isJunk) ? try await notSpamWork(context) : try await spamWork(context)
        case QuickActionStep.applyTag:
            guard
                let remote = step.tagRemoteId,
                let tag = try await store.tags(accountId: accountId).first(where: { $0.remoteId == remote })
            else {
                warnings.append(String(localized: "Could not apply tag, configured tag not found"))
                return nil
            }
            let labels = try await store.messageTagLabels(messageIds: messages.map(\.id))
            let lacking = messages.filter { labels[$0.id]?.contains(tag.imapLabel) != true }.map(\.id)
            guard !lacking.isEmpty else { return nil }
            return Work(
                operations: [
                    QueuedOperation(
                        accountId: accountId, operation: .setTag(messageIds: lacking, imapLabel: tag.imapLabel))
                ],
                undo: [
                    QueuedOperation(
                        accountId: accountId, operation: .unsetTag(messageIds: lacking, imapLabel: tag.imapLabel))
                ]
            )
        case QuickActionStep.markAsImportant:
            return Self.flagWork(messages, accountId: accountId, key: "important", value: true, reading: \.isImportant)
        case QuickActionStep.markAsFavorite:
            return Self.flagWork(messages, accountId: accountId, key: "flagged", value: true, reading: \.isFlagged)
        case QuickActionStep.markAsRead:
            return Self.flagWork(messages, accountId: accountId, key: "seen", value: true, reading: \.isSeen)
        case QuickActionStep.markAsUnread:
            return Self.flagWork(messages, accountId: accountId, key: "seen", value: false, reading: \.isSeen)
        case QuickActionStep.moveThread:
            guard
                let remote = step.mailboxRemoteId,
                let destination = try await store.mailboxes(accountId: accountId).first(where: { $0.remoteId == remote }
                )
            else {
                warnings.append(String(localized: "Could not move thread, destination mailbox not found"))
                return nil
            }
            let operations: [QueuedOperation] =
                switch context.selection.scope {
                case .messages:
                    [
                        QueuedOperation(
                            accountId: accountId,
                            operation: .move(messageIds: context.messageIds, destinationMailboxId: destination.id))
                    ]
                case .threads:
                    context.threadRoots.map {
                        QueuedOperation(
                            accountId: accountId,
                            operation: .moveThread(rootId: $0, destinationMailboxId: destination.id))
                    }
                }
            return Work(operations: operations, undo: Self.moveBack(messages))
        case QuickActionStep.deleteThread:
            let trash = try await context.queue.localMailboxId(for: .trash, accountId: accountId)
            let operations: [QueuedOperation] =
                switch context.selection.scope {
                case .messages:
                    [QueuedOperation(accountId: accountId, operation: .delete(messageIds: context.messageIds))]
                case .threads:
                    context.threadRoots.map {
                        QueuedOperation(accountId: accountId, operation: .deleteThread(rootId: $0))
                    }
                }
            return Work(
                operations: operations, undo: Self.moveBack(messages.filter { trash != nil && $0.mailboxId != trash }))
        default:
            // The record lists `snooze` as a step name, but the web's editor never offers it
            // and its executor has no case for it; skipped the same way.
            Self.logger.info("quick action step \(step.name, privacy: .public) is not executable")
            return nil
        }
    }

    /// Sets one flag to `value` on the messages that differ; the inverse puts theirs back.
    private static func flagWork(
        _ messages: [MessageRecord], accountId: Int64, key: String, value: Bool,
        reading flag: KeyPath<MessageRecord, Bool>
    ) -> Work? {
        let changing = messages.filter { $0[keyPath: flag] != value }.map(\.id)
        guard !changing.isEmpty else { return nil }
        return Work(
            operations: [
                QueuedOperation(accountId: accountId, operation: .setFlags(messageIds: changing, flags: [key: value]))
            ],
            undo: [
                QueuedOperation(accountId: accountId, operation: .setFlags(messageIds: changing, flags: [key: !value]))
            ]
        )
    }

    // MARK: - Availability and reading

    /// The v2 actions' availability, merged into ``availability``.
    func v2Availability(records: [MessageRecord], accountIds: [Int64]) -> [TriageAction: TriageAvailability] {
        var result: [TriageAction: TriageAvailability] = [:]
        let oneAccount: TriageAvailability =
            accountIds.count > 1
            ? .unavailable(String(localized: "Messages from more than one account have different tags."))
            : .available
        result[.editTags] = oneAccount
        result[.quickAction] =
            accountIds.count > 1 ? .unavailable(String(localized: "Quick actions belong to one account.")) : .available
        result[.snooze] =
            selectionIsSnoozed ? .unavailable(String(localized: "Already snoozed.")) : .available
        result[.unsnooze] =
            selectionIsSnoozed ? .available : .unavailable(String(localized: "Only snoozed messages can be unsnoozed."))
        result[.editAsNew] =
            records.count == 1 ? .available : .unavailable(String(localized: "Select one message to edit as new."))
        // Not spam needs no Junk folder: the flags are the change, the move is a bonus.
        if selectionIsJunk { result[.junk] = .available }
        return result
    }

    func inboxId(accountId: Int64) async throws -> Int64? {
        try await store.mailboxes(accountId: accountId).first { $0.specialRole?.lowercased() == "inbox" }?.id
    }

    /// The selection's messages, threads expanded to every member.
    func expanded(_ selection: Selection) async throws -> [MessageRecord] {
        try await contexts(for: selection).flatMap(\.expanded)
    }
}

/// A quick action ready to run on the selection: its steps, ordered, all allowed.
struct RunnableQuickAction: Identifiable, Equatable, Sendable {
    let id: Int64
    let accountId: Int64
    let name: String
    let steps: [QuickActionStepRecord]
}

/// The step names the server stores, and which ACL each one needs (the web's
/// `filteredQuickActions`).
enum QuickActionStep {
    static let markAsSpam = "markAsSpam"
    static let applyTag = "applyTag"
    static let moveThread = "moveThread"
    static let deleteThread = "deleteThread"
    static let markAsRead = "markAsRead"
    static let markAsUnread = "markAsUnread"
    static let markAsImportant = "markAsImportant"
    static let markAsFavorite = "markAsFavorite"

    static func permitted(_ name: String, rights: MailboxRights) -> Bool {
        switch name {
        case markAsSpam, applyTag, markAsImportant, markAsFavorite: rights.canWrite
        case markAsRead, markAsUnread: rights.canSetSeen
        case moveThread, deleteThread: rights.canDelete
        default: true
        }
    }

    /// A step after which the message has left the list.
    static func isTerminal(_ name: String) -> Bool {
        [markAsSpam, moveThread, deleteThread].contains(name)
    }
}
