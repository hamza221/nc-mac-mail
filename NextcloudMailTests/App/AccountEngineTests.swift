// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// One footer line for any number of accounts (ADR-0048).
///
/// The coordinators themselves are covered by `NCMailSync`'s own tests against a fake
/// transport; what is app-side logic, and what a second account could quietly break, is the
/// arithmetic that turns N progress values into the one the footer draws.
@Suite("AccountEngine progress aggregation")
struct AccountEngineTests {
    private static let backfilling = MirrorProgress(
        totalMessages: 1000,
        bodiesPresent: 400,
        bodiesFailed: 0,
        mailboxesRemaining: 2
    )

    private static let finished = MirrorProgress(
        totalMessages: 30,
        bodiesPresent: 28,
        bodiesFailed: 2,
        mailboxesRemaining: 0
    )

    @Test("nothing has reported yet, so the footer shows nothing")
    func nothingReported() {
        #expect(AccountEngine.combined(progress: []) == nil)
    }

    @Test("one account is passed through unchanged")
    func onePassesThrough() {
        #expect(AccountEngine.combined(progress: [Self.backfilling]) == Self.backfilling)
    }

    @Test("two accounts' counts add up")
    func twoAddUp() throws {
        let combined = try #require(AccountEngine.combined(progress: [Self.backfilling, Self.finished]))
        #expect(combined.totalMessages == 1030)
        #expect(combined.bodiesPresent == 428)
        #expect(combined.bodiesFailed == 2)
        #expect(combined.mailboxesRemaining == 2)
    }

    /// The reason a sum was worth a test: one finished account must not clear the footer
    /// while the other is still downloading.
    @Test("a finished account does not clear the footer for an unfinished one")
    func oneFinishedDoesNotClear() throws {
        let combined = try #require(AccountEngine.combined(progress: [Self.finished, Self.backfilling]))
        #expect(combined.isComplete == false)
    }

    @Test("the footer clears when every account has finished")
    func allFinished() throws {
        let combined = try #require(AccountEngine.combined(progress: [Self.finished, Self.finished]))
        #expect(combined.isComplete)
    }
}
