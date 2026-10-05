// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore

/// When a 401 becomes the session-expired modal (WS-25; ux-spec.md, "Authentication lost
/// (401) → modal").
///
/// Two sources reach it. Discovery's 401 at launch or sign-in goes straight to
/// ``fire(sessionId:)``. A 401 later in the session lands as `unauthorized` in a mailbox's
/// `lastSyncError` — a mailbox sync, a stage-1 page or a body fetch — and reaches
/// ``observe(_:accountId:sessionId:)`` through the store.
///
/// Once per login until it signs in again: a revoked password fails every mailbox of every
/// account on every pass, and that storm is one modal, not dozens. Only a failure recorded
/// after the account's first emission counts, so the stale `unauthorized` still in the
/// rows right after signing in again — cleared only by the next successful sync — does not
/// raise the modal straight back up. Every other error is the footer's and the Get info
/// panel's, never a modal.
nonisolated struct SessionExpiryTrigger {
    /// Logins the modal has been raised for since they last signed in.
    private var fired: Set<String> = []
    /// Per running account: each failing mailbox's failure count at the last emission.
    private var seen: [Int64: [Int64: Int]] = [:]

    /// `describe(_:)`'s rendering of `MailError.unauthorized`, which is a prefix check
    /// because the column is a case name and may grow detail.
    static func isAuthenticationLost(_ lastSyncError: String?) -> Bool {
        lastSyncError?.hasPrefix("unauthorized") == true
    }

    /// True the first time it is asked for a login, and false after that until
    /// ``reset(sessionId:)``.
    mutating func fire(sessionId: String) -> Bool {
        fired.insert(sessionId).inserted
    }

    /// One emission of an account's failing mailboxes. True when a mailbox recorded a new
    /// `unauthorized` since the previous emission and the login has not fired yet.
    mutating func observe(_ failures: [MailboxSyncFailure], accountId: Int64, sessionId: String) -> Bool {
        let previous = seen[accountId]
        seen[accountId] = Dictionary(uniqueKeysWithValues: failures.map { ($0.id, $0.syncFailureCount) })
        // The first emission is what the rows already said before this account started.
        guard let previous else { return false }
        let isNew = failures.contains { failure in
            Self.isAuthenticationLost(failure.lastSyncError)
                && failure.syncFailureCount > previous[failure.id, default: 0]
        }
        return isNew && fire(sessionId: sessionId)
    }

    /// The account stopped; a restarted one takes a fresh first emission.
    mutating func forget(accountId: Int64) {
        seen[accountId] = nil
    }

    /// The login signed in again or signed out: the next 401 is news.
    mutating func reset(sessionId: String) {
        fired.remove(sessionId)
    }
}
