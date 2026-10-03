// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// How far the mirror has got, counted from the rows rather than tracked in a variable.
///
/// Computed means it is right after a crash, right after a restore, and needs no bookkeeping
/// that could disagree with the data. Stage 1 reports `mailboxesRemaining`, stage 2 reports
/// messages; neither reports a percentage of a total the app does not know yet.
public struct MirrorProgress: FetchableRecord, Decodable, Sendable, Equatable {
    /// Envelopes mirrored so far. It grows while stage 1 runs, so it is not a denominator.
    public var totalMessages: Int
    public var bodiesPresent: Int
    public var bodiesFailed: Int
    /// Mirrored mailboxes whose envelope enumeration has not finished.
    public var mailboxesRemaining: Int

    public init(totalMessages: Int, bodiesPresent: Int, bodiesFailed: Int, mailboxesRemaining: Int) {
        self.totalMessages = totalMessages
        self.bodiesPresent = bodiesPresent
        self.bodiesFailed = bodiesFailed
        self.mailboxesRemaining = mailboxesRemaining
    }

    /// True once every mirrored mailbox is enumerated and no body is still outstanding.
    public var isComplete: Bool {
        mailboxesRemaining == 0 && bodiesPresent + bodiesFailed == totalMessages
    }
}
