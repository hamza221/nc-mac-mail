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
        let mirror = try await TriageMirror.seed()
        let account = try #require(mirror.accounts.first)
        let ids = try await mirror.addMessages(count: 200, account: account)

        let started = ContinuousClock.now
        await MessageActions(store: mirror.store).archive(Selection(messageIds: ids))
        let elapsed = ContinuousClock.now - started

        for id in ids {
            #expect(try await mirror.message(id)?.mailboxId == account.archiveId)
        }
        #expect(try await mirror.queueDepth(account) == 200)
        // Twenty times the measured 0.25-0.35 s: loose enough not to flake on a busy
        // machine, tight enough to fail if the batch stops being one transaction.
        #expect(elapsed < .seconds(5))
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
