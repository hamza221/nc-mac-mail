// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// The sidebar footer's priority order, one test per rung.
///
/// `docs/product/ux-spec.md#sidebar` numbers it: backfill progress, then "Offline", then the
/// count of waiting actions, then nothing. The order only earns its keep when two of them are
/// true at once, so every test here sets at least two and checks which one survives.
@Suite("AppStatus display priority")
struct AppStatusTests {
    /// Stage 1 still running: one mailbox left to enumerate.
    private static let backfilling = MirrorProgress(
        totalMessages: 48902,
        bodiesPresent: 12431,
        bodiesFailed: 0,
        mailboxesRemaining: 1
    )

    /// Every mailbox enumerated and every body accounted for, two of them as failures.
    private static let finished = MirrorProgress(
        totalMessages: 10,
        bodiesPresent: 8,
        bodiesFailed: 2,
        mailboxesRemaining: 0
    )

    @Test("a fresh status shows nothing")
    func quietByDefault() {
        let status = AppStatus()
        #expect(status.mirror == nil)
        #expect(status.isOffline == false)
        #expect(status.pendingFailures == 0)
        #expect(status.display == .none)
    }

    @Test("backfill progress outranks everything else")
    func mirroringWins() {
        let status = AppStatus()
        status.mirror = Self.backfilling
        status.isOffline = true
        status.pendingFailures = 3
        #expect(status.display == .mirroring(Self.backfilling))
    }

    @Test("a finished mirror stops claiming the footer")
    func completeMirrorYieldsToOffline() {
        let status = AppStatus()
        status.mirror = Self.finished
        status.isOffline = true
        status.pendingFailures = 3
        #expect(status.display == .offline)
    }

    @Test("offline outranks waiting actions")
    func offlineWinsOverPendingFailures() {
        let status = AppStatus()
        status.isOffline = true
        status.pendingFailures = 2
        #expect(status.display == .offline)
    }

    @Test("waiting actions show once the mirror is done and the route is back")
    func pendingFailuresShowLast() {
        let status = AppStatus()
        status.mirror = Self.finished
        status.isOffline = false
        status.pendingFailures = 2
        #expect(status.display == .pendingFailures(2))
    }

    @Test("an empty queue is not a message")
    func zeroFailuresIsNotADisplay() {
        let status = AppStatus()
        status.mirror = Self.finished
        status.pendingFailures = 0
        #expect(status.display == .none)
    }
}
