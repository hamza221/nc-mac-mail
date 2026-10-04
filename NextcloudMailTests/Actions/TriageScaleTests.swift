// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// What a triage pass costs, measured rather than described.
///
/// The brief asks what a 200-message batch does to the drain. These tests measure the half
/// this workstream owns: turning a selection into local rows and queue rows. The drain's own
/// costs are `OperationDrainScaleTests` in `NCMailSync`, and neither number is a live
/// round-trip time.
///
/// Measured, three runs each, Debug build, in-memory mirror: archiving 200 messages takes
/// **0.25–0.35 s**, and marking a thousand read takes **0.27–0.35 s**. Both are dominated by
/// `MessageActions.records(for:)`, which reads each message with its own
/// `MailStore.message(id:)` — 200 and 1000 point queries respectively. The enqueue itself is
/// one transaction in both cases. A `MailStore.messages(ids:)` batch reader is the fix and is
/// a request in this workstream's report, not an optimisation made without a number.
@Suite("Triage at scale")
@MainActor
struct TriageScaleTests {
    @Test("archiving 200 messages is one transaction and 200 promises")
    func twoHundredArchivedAtOnce() async throws {
        // The budget is about the batch, not about how many sibling suites a full run
        // executes in parallel: a busy run was measured at 7.4 s for one attempt. So a fresh
        // mirror is archived up to five times and the fastest attempt is judged, and a quiet
        // machine stops after the first. "One transaction" is proven by `archiveTwoHundred`
        // directly, which no amount of contention can fail.
        let budget = Duration.seconds(5)
        var samples: [Duration] = []
        for _ in 0..<5 {
            let elapsed = try await archiveTwoHundred()
            samples.append(elapsed)
            if elapsed < budget { break }
        }
        let best = try #require(samples.min())
        let report = samples.map(Self.milliseconds).joined(separator: ", ")
        FileHandle.standardError.write(
            Data("  [measured] archive 200: attempts \(report) ms; best \(Self.milliseconds(best)) ms\n".utf8))
        // Fifteen times the measured 0.25-0.35 s.
        #expect(best < budget)
    }

    /// Archives 200 messages of a fresh mirror and returns how long the archive took.
    ///
    /// The inbox's counts are observed across it. The mirror is a `DatabaseQueue`, whose
    /// observations fetch on the writer right after every commit and deliver every value in
    /// order, so a batch split over several transactions would show an inbox count between
    /// 200 and 0. Only 200 and 0 ever appearing is the single transaction, seen.
    private func archiveTwoHundred() async throws -> Duration {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let ids = try await mirror.addMessages(count: 200, account: account)

        var elapsed: Duration?
        var seen: [Int] = []
        // The first value is the inbox before the archive, read once the observation is
        // tracking, so no commit of the archive can slip in ahead of it.
        for try await counts in mirror.store.observeMailboxCounts(mailboxId: account.inboxId) {
            seen.append(counts.messageCount)
            if elapsed == nil {
                let started = ContinuousClock.now
                await MessageActions(store: mirror.store).archive(Selection(messageIds: ids))
                elapsed = ContinuousClock.now - started

                var misplaced = 0
                for id in ids {
                    if try await mirror.message(id)?.mailboxId != account.archiveId { misplaced += 1 }
                }
                #expect(try await mirror.queueDepth(account) == 200)
                // Every row left the inbox, so a commit that emptied it happened and its
                // value is on its way: the loop below ends rather than waits forever.
                try #require(misplaced == 0)
            }
            if counts.messageCount == 0 { break }
        }
        #expect(seen.first == 200)
        #expect(seen.last == 0)
        #expect(seen.allSatisfy { $0 == 200 || $0 == 0 }, "inbox counts seen: \(seen)")
        return try #require(elapsed)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.0f", Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
    }

    @Test("marking a thousand unread messages read is one transaction")
    func markAllReadOnAThousand() async throws {
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        try await mirror.addMessages(count: 1000, account: account)

        let started = ContinuousClock.now
        await MessageActions(store: mirror.store).markAllRead(mailboxId: account.inboxId)
        let elapsed = ContinuousClock.now - started

        #expect(try await mirror.queueDepth(account) == 1000)
        // Thirty times the measured 0.27-0.35 s.
        #expect(elapsed < .seconds(10))
    }
}
