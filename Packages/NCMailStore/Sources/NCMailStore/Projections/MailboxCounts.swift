// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// What the mirror holds for one mailbox, counted from its `message` rows.
///
/// The sidebar's Get info panel shows these beside the server's own figures on
/// ``MailboxRecord``, so the two can disagree visibly while a mailbox is still being
/// enumerated -- which is the point of showing both. Computed, like ``MirrorProgress``, so it
/// is right after a crash and needs no bookkeeping.
public struct MailboxCounts: FetchableRecord, Decodable, Sendable, Equatable {
    /// Envelopes mirrored locally.
    public var messageCount: Int
    /// Local messages with `isSeen = 0`.
    public var unreadCount: Int
    public var bodiesPresent: Int
    public var bodiesFailed: Int

    public init(messageCount: Int, unreadCount: Int, bodiesPresent: Int, bodiesFailed: Int) {
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.bodiesPresent = bodiesPresent
        self.bodiesFailed = bodiesFailed
    }

    public static let empty = MailboxCounts(messageCount: 0, unreadCount: 0, bodiesPresent: 0, bodiesFailed: 0)
}
