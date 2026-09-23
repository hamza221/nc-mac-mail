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
        case .delete, .deleteThread:
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
        switch kind {
        case .moveThread, .deleteThread:
            return row.threadRootId.map(Subject.thread)
        case .setFlags, .move, .delete:
            return row.messageId.map(Subject.message)
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
        return merged
    }
}
