// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// Which mailboxes are due, and in what order.
///
/// A value with one pure function, kept out of ``SyncScheduler`` on purpose. The cadence
/// table in `sync-engine.md` — two minutes for the selected mailbox and every inbox, ten for
/// the rest, round-robin, three at a time — is the part most likely to be got subtly wrong,
/// and it is the part that is hardest to test through an actor that also makes requests.
/// Here it is a function from four numbers to a list, and
/// `SyncCadenceTests` walks a week of it without a clock or a socket.
struct SyncCadence: Sendable {
    /// What the cadence needs to know about one mailbox. Deliberately not `MailboxRecord`:
    /// the decision depends on four facts, and a function taking thirty columns invites
    /// someone to add a fifth rule that reads a thirty-first.
    struct MailboxState: Sendable, Equatable {
        var id: Int64
        /// Every account's inbox syncs at the foreground interval whether or not it is on
        /// screen, because that is where mail people are waiting for arrives.
        var isInbox: Bool
        var lastSuccessAt: Int64?
        /// Set by a failure backoff. A mailbox is skipped until this passes even when its
        /// interval has elapsed, which is what stops one broken folder spending the whole
        /// request budget.
        var nextAttemptAt: Int64?
    }

    var configuration: SyncConfiguration

    /// Seconds between passes of one mailbox.
    func interval(for mailbox: MailboxState, selected: Int64?) -> Int64 {
        if mailbox.isInbox || mailbox.id == selected { return configuration.foregroundInterval }
        return configuration.backgroundInterval
    }

    /// The mailboxes to sync now, most-neglected first.
    ///
    /// The order is the round-robin: sorting by `lastSuccessAt` ascending and then taking
    /// the first ``SyncConfiguration/mailboxConcurrency`` means the folder that has waited
    /// longest goes next, so a ten-mailbox account cycles evenly instead of always syncing
    /// whichever three sort first by name. The selected mailbox is pulled to the front of
    /// that order because it is the one the user is looking at.
    func due(at now: Int64, mailboxes: [MailboxState], selected: Int64?) -> [Int64] {
        mailboxes
            .filter { mailbox in
                if let nextAttemptAt = mailbox.nextAttemptAt, now < nextAttemptAt { return false }
                guard let last = mailbox.lastSuccessAt else { return true }
                return now - last >= interval(for: mailbox, selected: selected)
            }
            .sorted { lhs, rhs in
                let leftRank = rank(lhs, selected: selected)
                let rightRank = rank(rhs, selected: selected)
                if leftRank != rightRank { return leftRank < rightRank }
                // `Int64.min` rather than 0 so a mailbox that has never succeeded sorts
                // ahead of one that succeeded at the epoch, which a fixture can produce.
                let left = lhs.lastSuccessAt ?? Int64.min
                let right = rhs.lastSuccessAt ?? Int64.min
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
            .map(\.id)
    }

    /// When the next mailbox falls due, so the loop can be told how long to wait rather than
    /// polling. Nil when nothing will ever be due, which only happens with no mailboxes.
    func nextDue(at now: Int64, mailboxes: [MailboxState], selected: Int64?) -> Int64? {
        mailboxes
            .map { mailbox in
                let ready = (mailbox.lastSuccessAt ?? Int64.min) + interval(for: mailbox, selected: selected)
                return max(ready, mailbox.nextAttemptAt ?? Int64.min, now)
            }
            .min()
    }

    private func rank(_ mailbox: MailboxState, selected: Int64?) -> Int {
        if mailbox.id == selected { return 0 }
        if mailbox.isInbox { return 1 }
        return 2
    }
}
