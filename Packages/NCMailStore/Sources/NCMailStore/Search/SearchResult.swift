// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// One hit: the list row, plus the two things a hit needs that a row in a mailbox does not.
///
/// `mailboxName` is here because "all mail" spans folders and accounts, and a result that
/// does not say where it lives sends the reader looking. `accountId` is here for the same
/// reason one level up — two accounts can both have an Archive.
///
/// The row is composed rather than flattened so there is exactly one definition of what a
/// list row is. `MessageRow` decodes from the same flat result row and ignores the two extra
/// columns, which is why this can be `FetchableRecord` without restating fourteen fields.
public struct SearchResult: FetchableRecord, Sendable, Identifiable, Equatable {
    public let message: MessageRow
    /// The mailbox's last path component, decoded — what the sidebar shows, not the IMAP path.
    public let mailboxName: String
    public let accountId: Int64

    public var id: Int64 { message.id }

    public init(row: Row) throws {
        message = try MessageRow(row: row)
        mailboxName = row["mailboxName"] ?? ""
        accountId = row["accountId"] ?? 0
    }
}

/// How much of the mirror the index actually covers, for the footer that says so.
///
/// Counted from `message.bodyState` rather than from the FTS table, and the difference
/// matters: every envelope in the mirror has an index row from the moment it is written, so
/// counting index rows would report 100% while most of the bodies were still downloading.
/// What the user needs to know is how many messages have their *body* searchable, which is
/// exactly what `bodyState = 'present'` records.
///
/// [ADR-0008](../../../../docs/decisions/0008-no-automatic-eviction.md)'s "Remove local
/// copies" empties the bodies again, so this can go back down. That is honest rather than
/// awkward: after reclaiming the space, search really does only cover subjects and people.
public struct SearchCoverage: FetchableRecord, Decodable, Sendable, Equatable {
    /// Messages whose body text is in the index.
    public var indexedMessages: Int
    /// Messages whose body download failed for good. They are never coming, so leaving them
    /// out of ``isComplete`` would pin the footer on screen forever.
    public var failedMessages: Int
    /// Every message in scope. The denominator the footer quotes as "downloaded messages",
    /// because an envelope in the mirror is a message the user can see in a list.
    public var totalMessages: Int
    /// Mailboxes in scope that hold no rows to search because nothing mirrors them.
    ///
    /// Unsubscribed mailboxes are not mirrored
    /// ([ADR-0007](../../../../docs/decisions/0007-subscribed-mailboxes-only.md)), so "all
    /// mail" is all *mirrored* mail. The count is here so the scope control can say so when
    /// there is something to say and stay quiet when there is not.
    public var unmirroredMailboxes: Int

    public init(indexedMessages: Int, failedMessages: Int, totalMessages: Int, unmirroredMailboxes: Int = 0) {
        self.indexedMessages = indexedMessages
        self.failedMessages = failedMessages
        self.totalMessages = totalMessages
        self.unmirroredMailboxes = unmirroredMailboxes
    }

    /// True when nothing further is going to be indexed, which is when the footer goes away.
    ///
    /// Also true for an empty scope: a footer reading "Searching 0 of 0" is noise.
    public var isComplete: Bool {
        indexedMessages + failedMessages >= totalMessages
    }
}
