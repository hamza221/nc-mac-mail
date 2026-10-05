// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

/// One line of the message list.
///
/// A projection, not a record: eighteen columns out of thirty-one. The difference is not
/// cosmetic — the list reads these for every visible row and fetching the body state, the
/// raw JSON and the references header along with them is how a list stops being instant.
///
/// `threadCount` and `threadUnreadCount` are 1 and 0/1 in the flat view and the real
/// per-thread numbers in the threaded one, so the row renders the same way in both.
public struct MessageRow: FetchableRecord, Decodable, Sendable, Identifiable, Equatable {
    public var id: Int64
    /// The server's `databaseId`, because every triage request is built from a selected row
    /// and takes the server's id, not the mirror's (ADR-0033).
    public var remoteId: Int64
    public var mailboxId: Int64
    public var accountId: Int64
    public var threadRootId: String?
    public var subject: String?
    public var previewText: String?
    /// The server's AI summary of the message (`message.summary`), when it has one.
    public var summary: String?
    public var senderEmail: String?
    public var senderName: String?
    public var sentAt: Int64
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var isImportant: Bool
    public var isDraft: Bool
    public var isEncrypted: Bool
    public var hasAttachments: Bool
    /// The list shows a "not downloaded" affordance offline, which needs this and nothing else
    /// from the body tables.
    public var bodyState: BodyState
    public var threadCount: Int
    public var threadUnreadCount: Int

    /// The column list, shared by every query that produces a row, so the flat view and the
    /// threaded view cannot drift into selecting different things.
    static let selection = """
        m.id AS id,
        m.remoteId AS remoteId,
        m.mailboxId AS mailboxId,
        m.accountId AS accountId,
        m.threadRootId AS threadRootId,
        m.subject AS subject,
        m.summary AS summary,
        m.previewText AS previewText,
        m.fromEmail AS senderEmail,
        m.fromLabel AS senderName,
        m.sentAt AS sentAt,
        m.isSeen AS isSeen,
        m.isFlagged AS isFlagged,
        m.isAnswered AS isAnswered,
        m.isImportant AS isImportant,
        m.isDraft AS isDraft,
        m.isEncrypted AS isEncrypted,
        m.hasAttachments AS hasAttachments,
        m.bodyState AS bodyState
        """
}
