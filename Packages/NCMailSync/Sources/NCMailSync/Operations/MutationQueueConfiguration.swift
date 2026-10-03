// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
internal import OSLog

/// Every number and every clock the queue uses.
///
/// `now` is injected for the reason `SyncConfiguration` injects it: a test that reads the
/// wall clock flakes, and `docs/architecture/concurrency.md` rules it out. There is no
/// `sleep` here at all — the drainer never waits, it stamps `nextAttemptAt` and returns, so
/// a backoff is a column rather than a suspended task that a quit would lose.
public struct MutationQueueConfiguration: Sendable {
    /// Seconds to wait after `n` consecutive failures of one operation, indexed from one.
    /// The last entry repeats, which is `offline-queue.md`'s "then every ten minutes".
    public var backoffSeconds: [Int64]
    /// How many attempts an operation makes before it becomes visible. Under this, retrying
    /// is normal and silence is correct.
    public var visibleAfterAttempts: Int
    /// Unix seconds.
    public var now: @Sendable () -> Int64
    /// Asks the sync engine to re-read one mailbox, for the 409/412 branch: the server won,
    /// and the only way to find out what it decided is to sync.
    ///
    /// A closure and not a `SyncScheduler` because the scheduler already holds the drainer,
    /// and a type that holds its holder is a retain cycle with extra steps.
    public var forceSync: (@Sendable (Int64) async -> Void)?
    /// Asks for one account to be re-read, for the 403 branch.
    public var refreshAccount: (@Sendable (Int64) async -> Void)?

    public init(
        backoffSeconds: [Int64] = [2, 8, 30, 120, 600],
        visibleAfterAttempts: Int = 5,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        forceSync: (@Sendable (Int64) async -> Void)? = nil,
        refreshAccount: (@Sendable (Int64) async -> Void)? = nil
    ) {
        self.backoffSeconds = backoffSeconds
        self.visibleAfterAttempts = max(1, visibleAfterAttempts)
        self.now = now
        self.forceSync = forceSync
        self.refreshAccount = refreshAccount
    }

    /// Seconds to wait after `attempts` consecutive failures.
    func backoff(after attempts: Int) -> Int64 {
        guard attempts >= 1, !backoffSeconds.isEmpty else { return 0 }
        return backoffSeconds[min(attempts - 1, backoffSeconds.count - 1)]
    }
}

/// What ``OperationDrainer/pendingCount`` publishes, and the whole of what WS-13 draws.
///
/// `offline-queue.md` allows exactly one indicator — "2 actions waiting" — and a popover
/// behind it. So there is one count for the popover's list and one for whether the indicator
/// appears at all, and no per-message anything.
public struct PendingSummary: Sendable, Equatable {
    /// Rows still to be sent, however healthy. The number that ticks down on reconnect.
    public var queued: Int
    /// Rows that have failed at least ``MutationQueueConfiguration/visibleAfterAttempts``
    /// times. The indicator appears only when this is above zero; `AppStatus.pendingFailures`
    /// is this number.
    public var failing: Int
    /// One entry per failing row, for the popover's list.
    public var failures: [PendingFailure]

    public init(queued: Int = 0, failing: Int = 0, failures: [PendingFailure] = []) {
        self.queued = queued
        self.failing = failing
        self.failures = failures
    }
}

/// One line of the failure popover.
///
/// No subject and no address: this reaches a view, and it also reaches the log through
/// ``PendingFailure/lastError``, which carries `MailError`'s description and nothing a user
/// wrote.
public struct PendingFailure: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: OperationKind
    /// Local message id, so the view can name the message by reading its own row.
    public var messageId: Int64?
    public var attempts: Int
    public var lastError: String?

    public init(id: Int64, kind: OperationKind, messageId: Int64?, attempts: Int, lastError: String?) {
        self.id = id
        self.kind = kind
        self.messageId = messageId
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// What the queue itself can fail with, as opposed to what the server answered.
public enum OperationError: Error, Sendable, CustomStringConvertible {
    /// `perform` was given an account the mirror has no row for.
    case accountNotMirrored(accountId: Int64)
    /// Every message id in the action had already gone from the mirror. Nothing was queued,
    /// because there is nothing left to describe.
    case noSuchMessages

    public var description: String {
        switch self {
        case .accountNotMirrored(let accountId): "accountNotMirrored(account: \(accountId))"
        case .noSuchMessages: "noSuchMessages"
        }
    }
}

/// One logger for the queue.
///
/// Nothing here ever interpolates a subject, an address, a mailbox name or a payload. Row
/// ids, message ids, kinds and counts are the whole vocabulary, which is why they are marked
/// `.public`: everything that could carry mail is simply absent.
enum OperationLog {
    static let queue = Logger(subsystem: "com.nextcloud.mail.macos", category: "queue")
}
