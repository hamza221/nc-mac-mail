// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Every number and every clock the mirror uses, in one value.
///
/// The defaults are the ones `docs/architecture/networking.md#concurrency-budget` and
/// `docs/architecture/local-mirror.md` specify. `now` and `sleep` are injected because a
/// test that reads the wall clock or waits on it is a test that flakes on a loaded CI
/// machine, and `docs/architecture/concurrency.md` rules both out.
public struct MirrorConfiguration: Sendable {
    /// Clamped server-side to 1...100. 100 is one request per hundred messages.
    public var envelopePageSize: Int
    /// Mailboxes enumerated at once. One page per mailbox, two per account.
    public var mailboxConcurrency: Int
    /// Body fetches at once, per account. ``MirrorBudget/shared`` caps the total.
    public var bodyConcurrency: Int
    /// How many message ids stage 2 claims from the database at a time. Large enough that
    /// the query is not run per message, small enough that a crash re-claims little.
    public var bodyBatchSize: Int
    /// How many times stage 0 re-sends `{"init": true}` after a 202 or a 428 before it
    /// gives the mailbox up for this pass.
    public var primeAttempts: Int
    /// Waits between those attempts. The last entry repeats if `primeAttempts` exceeds it.
    public var primeBackoff: [Duration]
    /// Consecutive `/body` failures before a message is marked `failed` and left to the
    /// deep reconcile rather than retried in a tight loop.
    public var bodyFailureLimit: Int
    /// How long a 429 or a 503 halves the body concurrency for, in seconds.
    public var throttleCooldownSeconds: Int64
    /// Unix seconds. Stamps `syncedAt` and `fetchedAt`, and measures the throttle cooldown.
    public var now: @Sendable () -> Int64
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Read rather than stored: Low Power Mode can change while the backfill runs, and the
    /// app shell's `NWPathMonitor` does not report it (it is a power fact, not a path one).
    public var isLowPowerModeEnabled: @Sendable () -> Bool

    public init(
        envelopePageSize: Int = 100,
        mailboxConcurrency: Int = 2,
        bodyConcurrency: Int = 2,
        bodyBatchSize: Int = 50,
        primeAttempts: Int = 5,
        primeBackoff: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)],
        bodyFailureLimit: Int = 3,
        throttleCooldownSeconds: Int64 = 600,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        isLowPowerModeEnabled: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.envelopePageSize = envelopePageSize
        self.mailboxConcurrency = mailboxConcurrency
        self.bodyConcurrency = bodyConcurrency
        self.bodyBatchSize = bodyBatchSize
        self.primeAttempts = primeAttempts
        self.primeBackoff = primeBackoff
        self.bodyFailureLimit = bodyFailureLimit
        self.throttleCooldownSeconds = throttleCooldownSeconds
        self.now = now
        self.sleep = sleep
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    func primeDelay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, !primeBackoff.isEmpty else { return nil }
        return primeBackoff[min(attempt - 1, primeBackoff.count - 1)]
    }
}

/// What the machine and the network are doing, as the app shell sees them.
///
/// The one `NWPathMonitor` lives in `NextcloudMail/Status` so that the backfill, the sync
/// scheduler and the drainer read one answer rather than three monitors disagreeing at the
/// edge of a change. `NCMailSync` cannot import an app-target type, so the shell pushes
/// this value in through ``MirrorCoordinator/apply(conditions:)`` instead.
public struct MirrorConditions: Sendable, Equatable {
    /// `NWPath.status != .satisfied`.
    public var isOffline: Bool
    /// `NWPath.isExpensive` — cellular, or a personal hotspot.
    public var isExpensive: Bool
    /// `NWPath.isConstrained` — the user turned Low Data Mode on for this network.
    public var isConstrained: Bool

    public init(isOffline: Bool = false, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isOffline = isOffline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Offline stops everything, because every stage is a request. Reconnecting resumes it
    /// with nothing lost: each page and each body is already committed.
    var stopsEverything: Bool { isOffline }

    /// An expensive or constrained network pauses stage 2 and never stage 1. Enumerating is
    /// a few kilobytes per hundred messages and it is what makes the app usable; bodies are
    /// the megabytes, and they can wait for wifi.
    var stopsBodies: Bool { isExpensive || isConstrained }
}

/// Why the mirror is not currently working, for the progress UI.
///
/// "Paused" and "stalled" look identical from outside, and
/// `docs/product/user-stories.md` S-02 asks the app to say which it is.
public enum MirrorPauseReason: String, Sendable, Equatable, CaseIterable {
    /// The user pressed Pause backfill. Survives a relaunch.
    case userRequested
    case offline
    case lowPowerMode
    case expensiveNetwork
    case constrainedNetwork
}
