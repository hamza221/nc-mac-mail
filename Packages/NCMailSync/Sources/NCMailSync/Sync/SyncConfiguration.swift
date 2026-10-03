// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// The two sizes the sync engine is built around, in one place so they are tunable from a
/// measurement rather than from taste.
///
/// `ADR-0015` makes the window the whole design: `POST /sync`'s `ids` is a window and not an
/// inventory, so the request and the response both scale with what is sent. Two hundred and
/// fifty ids is about 1.6 KB up and — because `changedMessages` returns every id that still
/// exists, there being no change detection server-side — about 250 envelopes down, whatever
/// the mailbox holds.
public enum SyncWindow {
    /// How many of a mailbox's most recent message ids each incremental sync claims.
    public static let size = 250

    /// The page size of the tail scan and of a deep reconcile. Clamped server-side to 1...100.
    public static let pageSize = 100
}

/// Every number and every clock the sync engine uses.
///
/// `now` and `sleep` are injected for the same reason `MirrorConfiguration` injects them: a
/// test that reads the wall clock or waits on it flakes on a loaded machine, and
/// `docs/architecture/concurrency.md` rules both out.
public struct SyncConfiguration: Sendable {
    /// How many of a mailbox's most recent ids one sync claims. ``SyncWindow/size`` is the
    /// only place the number itself lives; this is how a test shrinks it.
    public var windowSize: Int
    /// Envelopes per tail-scan and per reconcile page. Clamped server-side to 1...100.
    public var pageSize: Int
    /// Seconds between passes of the selected mailbox and of every inbox.
    public var foregroundInterval: Int64
    /// Seconds between passes of every other mirrored mailbox, round-robin.
    public var backgroundInterval: Int64
    /// Seconds between folder-list refreshes. `GET /mailboxes` plus `GET /accounts`.
    public var mailboxListInterval: Int64
    /// Seconds between automatic deep reconciles of one account. A week.
    public var deepReconcileInterval: Int64
    /// How often the periodic loop wakes to ask what is due. Not a sync interval: a pass
    /// only runs for the mailboxes ``SyncCadence`` says are due.
    public var tick: Duration
    /// Mailboxes synced at once within one account.
    public var mailboxConcurrency: Int
    /// How many times a 202 is answered by asking again before the mailbox is left for the
    /// next cycle. The client deliberately does not retry a 202 (`networking.md`), because
    /// only the sync engine knows what window it sent.
    public var syncInProgressAttempts: Int
    /// Waits between those attempts. The last entry repeats.
    public var syncInProgressBackoff: [Duration]
    /// Seconds added before a failed mailbox is tried again, indexed by consecutive failure
    /// count. The last entry repeats.
    public var failureBackoffSeconds: [Int64]
    /// How long a 429 or a 503 halves mailbox concurrency for, in seconds.
    public var throttleCooldownSeconds: Int64
    /// How many pages one tail scan may walk before it gives up and leaves the rest to the
    /// deep reconcile. Without it, a client returning from a fortnight offline would
    /// re-enumerate whole mailboxes inside a two-minute loop.
    public var tailScanPageLimit: Int
    /// Unix seconds.
    public var now: @Sendable () -> Int64
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        windowSize: Int = SyncWindow.size,
        pageSize: Int = SyncWindow.pageSize,
        foregroundInterval: Int64 = 120,
        backgroundInterval: Int64 = 600,
        mailboxListInterval: Int64 = 3600,
        deepReconcileInterval: Int64 = 7 * 24 * 3600,
        tick: Duration = .seconds(15),
        mailboxConcurrency: Int = 3,
        syncInProgressAttempts: Int = 5,
        syncInProgressBackoff: [Duration] = [.seconds(30)],
        failureBackoffSeconds: [Int64] = [30, 120, 600],
        throttleCooldownSeconds: Int64 = 600,
        tailScanPageLimit: Int = 20,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.windowSize = max(1, windowSize)
        self.pageSize = min(max(pageSize, 1), 100)
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
        self.mailboxListInterval = mailboxListInterval
        self.deepReconcileInterval = deepReconcileInterval
        self.tick = tick
        self.mailboxConcurrency = mailboxConcurrency
        self.syncInProgressAttempts = syncInProgressAttempts
        self.syncInProgressBackoff = syncInProgressBackoff
        self.failureBackoffSeconds = failureBackoffSeconds
        self.throttleCooldownSeconds = throttleCooldownSeconds
        self.tailScanPageLimit = tailScanPageLimit
        self.now = now
        self.sleep = sleep
    }

    func syncInProgressDelay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, !syncInProgressBackoff.isEmpty else { return nil }
        return syncInProgressBackoff[min(attempt - 1, syncInProgressBackoff.count - 1)]
    }

    /// Seconds to wait after `failures` consecutive failures of one mailbox.
    func failureBackoff(after failures: Int) -> Int64 {
        guard failures >= 1, !failureBackoffSeconds.isEmpty else { return 0 }
        return failureBackoffSeconds[min(failures - 1, failureBackoffSeconds.count - 1)]
    }
}
