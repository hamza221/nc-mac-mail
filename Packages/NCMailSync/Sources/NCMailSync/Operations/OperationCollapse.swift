// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import NCMailStore

/// Several queue rows folded into the one request that will satisfy all of them.
///
/// ``absorbedIds`` is what makes the fold safe to act on: a 2xx deletes every row it names,
/// a failure reschedules every row it names, and a discard reverts to ``payload``'s snapshot,
/// which is the state before the *first* of them. Star, unstar, star is one request and one
/// entry in the failure popover, not three.
struct CollapsedOperation: Sendable, Equatable {
    var kind: OperationKind
    var accountId: Int64
    /// Local message id. Nil only for a thread operation whose anchor has gone.
    var messageId: Int64?
    var threadRootId: String?
    var payload: OperationPayload
    /// Every row id this stands for, oldest first. Its own included.
    var absorbedIds: [Int64]
    /// The highest attempt count among the absorbed rows, which is what decides visibility.
    var attempts: Int
    var lastError: String?
    var nextAttemptAt: Int64?
    /// True while a request for one of the absorbed rows is outstanding.
    var isInFlight: Bool

    /// The id the popover and ``OperationDrainer/discard(operationId:)`` use, and the id the
    /// drain orders by: the oldest row of the fold, so "order across messages is preserved"
    /// means what it says.
    var id: Int64 { absorbedIds.first ?? 0 }
}

/// The collapsing rules from `offline-queue.md`, as a pure function over rows.
///
/// Pure on purpose. The rules are the part of this workstream most likely to be argued about
/// later, and a function with no store and no clock in it can be tested by listing rows and
/// reading the answer.
enum OperationCollapse {
    /// One key per thing an operation is *about*. Two messages never collapse into each
    /// other, and neither does a thread operation into a message operation for one of its
    /// members: the requests differ, and guessing that they agree is how a thread ends up
    /// half moved.
    private enum Subject: Hashable {
        case message(Int64)
        case thread(String)
        /// Lowercased, so `Ann@x` and `ann@x` are one sender and the later choice wins.
        case sender(String)
        /// A v2 row's subject: a mailbox, a preference key, a settings row by server id, a
        /// DAV href.
        case row(String)
        /// A row that never collapses with anything: creates and one-shot actions.
        case unique(Int64)
    }

    /// - Parameter rows: the account's queue, any order.
    /// - Returns: the work to do, oldest first.
    static func collapse(_ rows: [PendingOperationRecord]) -> [CollapsedOperation] {
        var stacks: [Subject: [CollapsedOperation]] = [:]

        for row in rows.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            guard
                let id = row.id,
                let kind = OperationKind(rawValue: row.kind),
                let subject = subject(of: row, kind: kind)
            else { continue }

            let item = CollapsedOperation(
                kind: kind,
                accountId: row.accountId,
                messageId: row.messageId,
                threadRootId: row.threadRootId,
                payload: OperationPayload.decode(row.payloadJSON),
                absorbedIds: [id],
                attempts: row.attempts,
                lastError: row.lastError,
                nextAttemptAt: row.nextAttemptAt,
                isInFlight: row.state == .inFlight
            )
            var stack = stacks[subject] ?? []

            if kind.isTerminal {
                // "Anything followed by delete becomes the delete." Everything queued for
                // this subject is now pointless, but the rows still have to be deleted, so
                // the delete inherits their ids — and their snapshot, so a discard goes back
                // to where the user started rather than to the middle of their triage pass.
                var folded = item
                folded.absorbedIds = stack.flatMap(\.absorbedIds) + [id]
                folded.attempts = max(item.attempts, stack.map(\.attempts).max() ?? 0)
                folded.isInFlight = item.isInFlight || stack.contains { $0.isInFlight }
                for earlier in stack.reversed() {
                    folded.payload.before = folded.payload.before.merging(earlier: earlier.payload.before)
                }
                // A DAV delete after puts: revert to the state before the first put, and send
                // with the precondition the server can still check.
                if let first = stack.first?.payload.dav, var dav = folded.payload.dav {
                    dav.before = first.before
                    dav.etag = first.etag ?? dav.etag
                    folded.payload.dav = dav
                }
                stack = [folded]
            } else if var last = stack.last, last.kind == kind, merge(item, into: &last) {
                stack[stack.count - 1] = last
            } else {
                stack.append(item)
            }
            stacks[subject] = stack
        }

        return stacks.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    /// Folds `item` into `last` when the rules allow, answering whether it did.
    private static func merge(_ item: CollapsedOperation, into last: inout CollapsedOperation) -> Bool {
        switch item.kind {
        case .setFlags:
            // "Consecutive setFlags on the same message merge, later keys win."
            last.payload.flags.merge(item.payload.flags) { _, later in later }
        case .move, .moveThread:
            // "A move followed by a move keeps the last destination."
            last.payload.destinationMailboxId = item.payload.destinationMailboxId
        case .trustSender:
            // Latest wins for the same sender: trust then untrust is one DELETE.
            last.payload.trusted = item.payload.trusted
            last.payload.senderEmail = item.payload.senderEmail
        case _ where item.kind.mergesWithItself:
            // A v2 setter: later intent wins (field by field for an account patch, edited
            // properties unioned for a vCard), the earliest `before` stays.
            if let earlier = last.payload.intent, let later = item.payload.intent {
                last.payload.intent = earlier.merging(later)
            } else if let later = item.payload.intent {
                last.payload.intent = later
            }
            if let earlier = last.payload.dav, let later = item.payload.dav {
                last.payload.dav = earlier.merging(later)
            }
        default:
            return false
        }
        last.payload.before = item.payload.before.merging(earlier: last.payload.before)
        last.absorbedIds.append(contentsOf: item.absorbedIds)
        last.attempts = max(last.attempts, item.attempts)
        last.lastError = item.lastError ?? last.lastError
        last.nextAttemptAt = item.nextAttemptAt
        last.isInFlight = last.isInFlight || item.isInFlight
        return true
    }

    private static func subject(of row: PendingOperationRecord, kind: OperationKind) -> Subject? {
        let unique = row.id.map(Subject.unique)
        switch kind {
        case .moveThread, .deleteThread, .snoozeThread, .unsnoozeThread:
            return row.threadRootId.map(Subject.thread)
        case .setFlags, .move, .delete, .snooze, .unsnooze:
            return row.messageId.map(Subject.message)
        case .setTag, .unsetTag:
            // A tag change on a message is absorbed by the message's delete, like its flags.
            return row.messageId.map(Subject.message)
        case .trustSender:
            return OperationPayload.decode(row.payloadJSON).senderEmail.map { Subject.sender($0.lowercased()) }
        case .createTag, .createMailbox, .createAlias, .createTextBlock, .createQuickAction, .clearMailbox,
            .markMailboxRead, .sendMDN, .unsubscribe, .saveToFiles, .addressBookShare, .contactSocialAvatar:
            return unique
        default:
            let payload = OperationPayload.decode(row.payloadJSON)
            guard let key = rowKey(kind, payload, accountId: row.accountId) else { return unique }
            return .row(key)
        }
    }

    /// What a v2 row is about. Kinds that share a key are about the same thing, so a delete
    /// absorbs the updates before it and two setters of one kind merge.
    private static func rowKey(_ kind: OperationKind, _ payload: OperationPayload, accountId: Int64) -> String? {
        if kind.isDAV { return payload.dav?.href.map { "dav:\($0)" } }
        guard let intent = payload.intent else { return nil }
        let target = intent.targetRemoteId.map(String.init) ?? intent.placeholder.map(String.init)
        switch kind {
        case .updateTag, .deleteTag:
            return target.map { "tag:\($0)" }
        case .renameMailbox, .moveMailbox, .deleteMailbox, .setMailboxSubscribed, .setMailboxSyncInBackground:
            return intent.mailboxId.map { "mailbox:\($0)" }
        case .setPreference:
            return intent.key.map { "preference:\(intent.loginId ?? 0):\($0)" }
        case .patchAccount, .setSignature:
            return "\(kind.rawValue):\(accountId)"
        case .updateAlias, .deleteAlias, .setAliasSignature:
            return target.map { "alias:\($0)" }
        case .updateTextBlock, .deleteTextBlock:
            return target.map { "textBlock:\($0)" }
        case .shareTextBlock, .unshareTextBlock:
            return target.map { "textBlockShare:\($0):\(intent.shareWith ?? "")" }
        case .updateQuickAction, .deleteQuickAction:
            return target.map { "quickAction:\($0)" }
        case .upsertActionStep, .deleteActionStep:
            return target.map { "actionStep:\(intent.parentRemoteId ?? 0):\($0)" }
        case .addInternalAddress, .removeInternalAddress:
            return intent.email.map { "internalAddress:\(intent.type ?? ""):\($0.lowercased())" }
        case .trustDomain:
            return intent.email.map { "trustedDomain:\($0.lowercased())" }
        default:
            return nil
        }
    }
}

extension OperationSnapshot {
    /// This snapshot with `earlier`'s values preferred wherever both describe the same thing.
    ///
    /// Reverting a fold has to reach the state before the oldest row in it, so the older
    /// value always wins and the newer only contributes keys the older never mentioned.
    func merging(earlier: OperationSnapshot) -> OperationSnapshot {
        var merged = self
        merged.messageIds = earlier.messageIds.isEmpty ? messageIds : earlier.messageIds
        merged.flags.merge(earlier.flags) { _, older in older }
        merged.mailboxIds.merge(earlier.mailboxIds) { _, older in older }
        if let earlierTrust = earlier.senderTrusted {
            merged.senderTrusted = (senderTrusted ?? [:]).merging(earlierTrust) { _, older in older }
        }
        merged.rows = earlier.rows ?? rows
        return merged
    }
}
