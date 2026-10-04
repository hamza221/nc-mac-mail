// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

/// Which end of the list comes first.
public enum MessageSortOrder: String, Sendable {
    case newest, oldest
}

/// What a message list shows: one or more mailboxes, optionally narrowed.
///
/// Every predicate applies to the drawn row — in the threaded view, to the newest message of
/// each thread — so a thread appears under "Flagged" when its newest message is flagged.
/// `nil` means "do not filter".
public struct MessageListQuery: Hashable, Sendable {
    /// The mailboxes whose messages are listed; more than one is a unified view, and an empty
    /// list means every mailbox of every account.
    public var mailboxIds: [Int64]
    public var isFlagged: Bool?
    public var isImportant: Bool?
    /// The row carries a tag with this IMAP label (e.g. `$follow_up`).
    public var tagImapLabel: String?
    /// The row was sent at or before this Unix time.
    public var sentAtOrBefore: Int64?

    public init(
        mailboxIds: [Int64],
        isFlagged: Bool? = nil,
        isImportant: Bool? = nil,
        tagImapLabel: String? = nil,
        sentAtOrBefore: Int64? = nil
    ) {
        self.mailboxIds = mailboxIds
        self.isFlagged = isFlagged
        self.isImportant = isImportant
        self.tagImapLabel = tagImapLabel
        self.sentAtOrBefore = sentAtOrBefore
    }
}

/// One attachment as the list shows it: a chip with a file name.
public struct AttachmentChip: Sendable, Equatable, Hashable {
    public var messageId: Int64
    public var attachmentId: String
    public var fileName: String
    public var mime: String?

    public init(messageId: Int64, attachmentId: String, fileName: String, mime: String? = nil) {
        self.messageId = messageId
        self.attachmentId = attachmentId
        self.fileName = fileName
        self.mime = mime
    }
}

extension MailStore {
    /// A window onto the messages matching `query`.
    ///
    /// `range` is a row window, as for ``messages(mailboxId:view:range:)``.
    public func messages(
        query: MessageListQuery,
        view: ListView,
        order: MessageSortOrder,
        range: Range<Int>
    ) async throws -> [MessageRow] {
        try await dbQueue.read { db in
            try Self.fetchMessages(db, query: query, view: view, order: order, range: range)
        }
    }

    public func observeMessages(
        query: MessageListQuery,
        view: ListView,
        order: MessageSortOrder,
        range: Range<Int>
    ) -> StoreObservation<[MessageRow]> {
        observation { db in
            try Self.fetchMessages(db, query: query, view: view, order: order, range: range)
        }
    }

    /// Every account's selectable inbox, by account then mailbox id — the unified inbox.
    public func inboxMailboxIds() async throws -> [Int64] {
        try await dbQueue.read { db in try Self.fetchInboxMailboxIds(db) }
    }

    public func observeInboxMailboxIds() -> StoreObservation<[Int64]> {
        observation { db in try Self.fetchInboxMailboxIds(db) }
    }

    /// The tags of each message in `messageIds`, by display name. Messages without tags are
    /// absent from the map.
    public func tags(messageIds: [Int64]) async throws -> [Int64: [TagRecord]] {
        try await dbQueue.read { db in try Self.fetchTags(db, messageIds: messageIds) }
    }

    public func observeTags(messageIds: [Int64]) -> StoreObservation<[Int64: [TagRecord]]> {
        observation { db in try Self.fetchTags(db, messageIds: messageIds) }
    }

    /// The non-inline, named attachments of each message in `messageIds`, in attachment-id
    /// order. Messages without any are absent from the map.
    public func attachmentChips(messageIds: [Int64]) async throws -> [Int64: [AttachmentChip]] {
        try await dbQueue.read { db in try Self.fetchAttachmentChips(db, messageIds: messageIds) }
    }

    public func observeAttachmentChips(messageIds: [Int64]) -> StoreObservation<[Int64: [AttachmentChip]]> {
        observation { db in try Self.fetchAttachmentChips(db, messageIds: messageIds) }
    }

    static func fetchMessages(
        _ db: Database,
        query: MessageListQuery,
        view: ListView,
        order: MessageSortOrder,
        range: Range<Int>
    ) throws -> [MessageRow] {
        guard !range.isEmpty else { return [] }
        let (sql, arguments) = MessageSQL.list(query: query, view: view, order: order)
        var all = arguments
        all += ["limit": range.count, "offset": range.lowerBound]
        return try MessageRow.fetchAll(db, sql: sql, arguments: all)
    }

    private static func fetchInboxMailboxIds(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM mailbox
                WHERE specialRole = 'inbox' AND isSelectable = 1
                ORDER BY accountId, id
                """
        )
    }

    private static func fetchTags(_ db: Database, messageIds: [Int64]) throws -> [Int64: [TagRecord]] {
        guard !messageIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT messageTag.messageId AS taggedMessageId, tag.* FROM tag
                JOIN messageTag ON messageTag.tagId = tag.id
                WHERE messageTag.messageId IN \(databaseQuestionMarks(count: messageIds.count))
                ORDER BY messageTag.messageId, tag.displayName, tag.id
                """,
            arguments: StatementArguments(messageIds)
        )
        var result: [Int64: [TagRecord]] = [:]
        for row in rows {
            let messageId: Int64 = row["taggedMessageId"]
            result[messageId, default: []].append(try TagRecord(row: row))
        }
        return result
    }

    private static func fetchAttachmentChips(
        _ db: Database,
        messageIds: [Int64]
    ) throws -> [Int64: [AttachmentChip]] {
        guard !messageIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT messageId, attachmentId, fileName, mime FROM attachment
                WHERE messageId IN \(databaseQuestionMarks(count: messageIds.count))
                  AND isInline = 0 AND fileName IS NOT NULL AND fileName <> ''
                ORDER BY messageId, attachmentId
                """,
            arguments: StatementArguments(messageIds)
        )
        var result: [Int64: [AttachmentChip]] = [:]
        for row in rows {
            let chip = AttachmentChip(
                messageId: row["messageId"],
                attachmentId: row["attachmentId"],
                fileName: row["fileName"],
                mime: row["mime"]
            )
            result[chip.messageId, default: []].append(chip)
        }
        return result
    }
}

extension MessageSQL {
    /// The list query for `query`, with named arguments for everything but `:limit` and
    /// `:offset`.
    ///
    /// One mailbox binds `:mailboxId` so the plan walks `idxMessageMailboxSent` without a
    /// sorter; several bind `:mailbox0…` in an `IN`, which sorts — a unified list pays for
    /// its union — and none lists every mailbox. The threaded branch's newest-in-thread test
    /// and both counts are scoped to
    /// the drawn row's own mailbox (`c.mailboxId = m.mailboxId`), so a thread spread over two
    /// inboxes shows once per inbox, each with that inbox's counts. See ``threadedList`` for
    /// why the shape is what it is.
    static func list(
        query: MessageListQuery,
        view: ListView,
        order: MessageSortOrder
    ) -> (sql: String, arguments: StatementArguments) {
        var arguments: StatementArguments = [:]
        var clauses: [String] = []

        if query.mailboxIds.count == 1 {
            clauses.append("m.mailboxId = :mailboxId")
            arguments += ["mailboxId": query.mailboxIds[0]]
        } else if !query.mailboxIds.isEmpty {
            let names = query.mailboxIds.indices.map { "mailbox\($0)" }
            clauses.append("m.mailboxId IN (" + names.map { ":" + $0 }.joined(separator: ", ") + ")")
            for (name, id) in zip(names, query.mailboxIds) {
                arguments += [name: id]
            }
        }
        if let isFlagged = query.isFlagged {
            clauses.append("m.isFlagged = :isFlagged")
            arguments += ["isFlagged": isFlagged]
        }
        if let isImportant = query.isImportant {
            clauses.append("m.isImportant = :isImportant")
            arguments += ["isImportant": isImportant]
        }
        if let label = query.tagImapLabel {
            clauses.append(
                """
                EXISTS (
                    SELECT 1 FROM messageTag mt JOIN tag t ON t.id = mt.tagId
                     WHERE mt.messageId = m.id AND t.imapLabel = :tagImapLabel
                )
                """)
            arguments += ["tagImapLabel": label]
        }
        if let sentAtOrBefore = query.sentAtOrBefore {
            clauses.append("m.sentAt <= :sentAtOrBefore")
            arguments += ["sentAtOrBefore": sentAtOrBefore]
        }

        let counts: String
        switch view {
        case .flat:
            counts = """
                1 AS threadCount,
                (CASE WHEN m.isSeen THEN 0 ELSE 1 END) AS threadUnreadCount
                """
        case .threaded:
            counts = """
                CASE WHEN m.threadRootId IS NULL THEN 1 ELSE (
                    SELECT count(*) FROM message c
                     WHERE c.mailboxId = m.mailboxId AND c.threadRootId = m.threadRootId
                ) END AS threadCount,
                CASE WHEN m.threadRootId IS NULL THEN (CASE WHEN m.isSeen THEN 0 ELSE 1 END) ELSE (
                    SELECT coalesce(sum(CASE WHEN c.isSeen THEN 0 ELSE 1 END), 0) FROM message c
                     WHERE c.mailboxId = m.mailboxId AND c.threadRootId = m.threadRootId
                ) END AS threadUnreadCount
                """
            clauses.append(
                """
                (
                    m.threadRootId IS NULL
                    OR m.id = (
                        SELECT c.id FROM message c
                         WHERE c.mailboxId = m.mailboxId AND c.threadRootId = m.threadRootId
                         ORDER BY c.sentAt DESC
                         LIMIT 1
                    )
                )
                """)
        }

        let sql = """
            SELECT
                \(MessageRow.selection),
                \(counts)
            FROM message m
            WHERE \(clauses.isEmpty ? "1" : clauses.joined(separator: "\n  AND "))
            ORDER BY m.sentAt \(order == .newest ? "DESC" : "ASC")
            LIMIT :limit OFFSET :offset
            """
        return (sql, arguments)
    }
}
