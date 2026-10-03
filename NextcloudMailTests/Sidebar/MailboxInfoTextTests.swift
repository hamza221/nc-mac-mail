// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// What the Get info panel says, from the rows alone.
@Suite("MailboxInfoText")
struct MailboxInfoTextTests {
    private func mailbox(isMirrored: Bool = true, envelopesComplete: Bool = true) -> MailboxRecord {
        MailboxRecord(
            id: 10,
            accountId: 1,
            remoteId: 1010,
            name: "INBOX",
            displayName: "INBOX",
            isSubscribed: isMirrored,
            isMirrored: isMirrored,
            envelopesComplete: envelopesComplete
        )
    }

    @Test("a folder whose every body is in or given up on reads as complete")
    func complete() {
        let counts = MailboxCounts(messageCount: 3, unreadCount: 1, bodiesPresent: 2, bodiesFailed: 1)
        #expect(MailboxInfoText.mirrorState(mailbox: mailbox(), counts: counts) == "Complete")
    }

    @Test("bodies still outstanding name how many remain")
    func bodiesRemaining() {
        let counts = MailboxCounts(messageCount: 10, unreadCount: 0, bodiesPresent: 3, bodiesFailed: 0)
        #expect(MailboxInfoText.mirrorState(mailbox: mailbox(), counts: counts).contains("7"))
    }

    @Test("an unmirrored folder says so rather than reporting zero progress")
    func notMirrored() {
        let text = MailboxInfoText.mirrorState(mailbox: mailbox(isMirrored: false), counts: .empty)
        #expect(text.hasPrefix("Not mirrored"))
    }

    @Test("a known failure is explained in words, not as its case name")
    func knownFailure() {
        let text = MailboxInfoText.failureExplanation("server(status: 500)")
        #expect(text != MailboxInfoText.failureExplanation(nil))
        #expect(!text.contains("status"))
    }

    @Test("an unrecognised stored error is never echoed")
    func unknownFailureIsNotEchoed() {
        let stored = "Something about ada@example.invalid"
        let text = MailboxInfoText.failureExplanation(stored)
        #expect(text == MailboxInfoText.failureExplanation(nil))
        #expect(!text.contains("ada@example.invalid"))
    }
}
