// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// When `MailClient` tries again, and how long it waits first.
///
/// The waiting is a closure so a test can assert on the schedule without
/// spending 40 seconds proving it. `sleep` and `jitter` are both injected; the
/// defaults are the real ones.
public struct RetryPolicy: Sendable {
    /// One entry per retry, so three delays mean up to four sends in total.
    public var delays: [Duration]
    /// Applied to each delay before sleeping. Two clients that back off in
    /// lockstep re-collide on the same second.
    public var jitter: @Sendable (Duration) -> Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        delays: [Duration],
        jitter: @escaping @Sendable (Duration) -> Duration = RetryPolicy.defaultJitter,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.delays = delays
        self.jitter = jitter
        self.sleep = sleep
    }

    /// 2 s, 8 s, 30 s, as `docs/architecture/networking.md` specifies.
    public static let standard = RetryPolicy(delays: [.seconds(2), .seconds(8), .seconds(30)])

    /// No retry at all, for a caller that owns its own policy.
    public static let none = RetryPolicy(delays: [])

    /// Full jitter: a uniform pick between zero and the delay. It spreads a
    /// thundering herd better than adding a small random tail does.
    public static let defaultJitter: @Sendable (Duration) -> Duration = { delay in
        let attoseconds = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
        guard attoseconds > 0 else { return delay }
        return .nanoseconds(Int64.random(in: 0...attoseconds))
    }

    /// How long to wait before attempt number `attempt`, counting the first
    /// send as attempt 0. Nil when there is nothing left to try.
    func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return jitter(delays[attempt - 1])
    }

    var maximumAttempts: Int { delays.count + 1 }
}
