// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import GRDB

extension MailStore {
    // MARK: - Writing

    /// Writes a page of envelopes, their addresses and their search-index rows in one
    /// transaction.
    ///
    /// One transaction is not tidiness. A crash between the envelope and its index row would
    /// leave a message that exists and cannot be found, and nothing would ever notice: the
    /// backfill would not revisit it, because as far as the cursor is concerned it is done.
    public func upsert(envelopes: [EnvelopeWrite]) async throws {
        guard !envelopes.isEmpty else { return }
        try await dbQueue.write { db in
            for envelope in envelopes {
                try envelope.upsert(db)

                // Rewritten rather than merged: a recipient removed server-side has to
                // disappear here too, and the addresses of one message are a handful of rows.
                try db.execute(
                    sql: "DELETE FROM messageAddress WHERE messageId = ?",
                    arguments: [envelope.id]
                )
                var nextPosition: [AddressKind: Int] = [:]
                for address in envelope.addresses {
                    let position = nextPosition[address.kind, default: 0]
                    nextPosition[address.kind] = position + 1
                    try MessageAddressRecord(
                        messageId: envelope.id,
                        kind: address.kind,
                        position: position,
                        email: address.email,
                        label: address.label
                    ).insert(db)
                }

                try SearchIndexWriter.indexEnvelope(
                    messageId: envelope.id,
                    subject: envelope.subject,
                    preview: envelope.previewText,
                    people: envelope.indexedPeople,
                    in: db
                )
            }
        }
    }

    /// Removes messages the server no longer has. The trigger takes their index rows.
    public func deleteMessages(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM message WHERE id IN \(databaseQuestionMarks(count: ids.count))",
                arguments: StatementArguments(ids)
            )
        }
    }

    // MARK: - Reading

    /// A window onto one mailbox, newest first.
    ///
    /// `range` is a row window, not a page number: the list asks for `0..<60`, then `0..<120`
    /// as it scrolls. Fifty thousand rows never become a fifty-thousand-element array.
    public func messages(mailboxId: Int64, view: ListView, range: Range<Int>) async throws -> [MessageRow] {
        try await dbQueue.read { db in
            try Self.fetchMessages(db, mailboxId: mailboxId, view: view, range: range)
        }
    }

    public func observeMessages(
        mailboxId: Int64,
        view: ListView,
        range: Range<Int>
    ) -> AsyncValueObservation<[MessageRow]> {
        ValueObservation
            .tracking { db in
                try Self.fetchMessages(db, mailboxId: mailboxId, view: view, range: range)
            }
            .values(in: dbQueue, scheduling: .mainActor)
    }

    /// Every message of one thread, oldest first, which is how a conversation reads.
    public func observeThread(rootId: String, mailboxId: Int64) -> AsyncValueObservation<[MessageRow]> {
        ValueObservation
            .tracking { db in
                try MessageRow.fetchAll(
                    db,
                    sql: MessageSQL.thread,
                    arguments: ["mailboxId": mailboxId, "rootId": rootId]
                )
            }
            .values(in: dbQueue, scheduling: .mainActor)
    }

    public func message(id: Int64) async throws -> MessageRecord? {
        try await dbQueue.read { db in
            try MessageRecord.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: [id])
        }
    }

    /// The next slice of stage-2 work: the account's newest messages with no body yet.
    ///
    /// Newest first because recency is what people open, and bounded because the scheduler
    /// holds a fixed number in flight rather than a list of everything outstanding.
    public func nextBodyBackfillBatch(accountId: Int64, limit: Int) async throws -> [Int64] {
        try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM message
                     WHERE accountId = :accountId AND bodyState = 'missing'
                     ORDER BY sentAt DESC
                     LIMIT :limit
                    """,
                arguments: ["accountId": accountId, "limit": limit]
            )
        }
    }

    static func fetchMessages(
        _ db: Database,
        mailboxId: Int64,
        view: ListView,
        range: Range<Int>
    ) throws -> [MessageRow] {
        guard !range.isEmpty else { return [] }
        return try MessageRow.fetchAll(
            db,
            sql: view == .threaded ? MessageSQL.threadedList : MessageSQL.flatList,
            arguments: [
                "mailboxId": mailboxId,
                "limit": range.count,
                "offset": range.lowerBound,
            ]
        )
    }
}

/// The three list queries, written out because they are the performance-critical part of the
/// application and deserve to be read rather than generated.
enum MessageSQL {
    /// One mailbox, newest first, straight down `idxMessageMailboxSent`.
    ///
    /// `ORDER BY m.sentAt DESC` and nothing else, deliberately. Adding `, m.id DESC` to break
    /// ties reads better and costs the index: `sentAt` is the last term
    /// `idxMessageMailboxSent` can satisfy, so SQLite sorts for the second one, and a sorted
    /// result cannot be cut short by the LIMIT. Measured over 50,000 rows that took the
    /// threaded list from 0.4 ms to 201 ms. Two messages with the same `dateInt` come out in
    /// index order, which is by ascending server id and stable across inserts, so a window
    /// does not reshuffle under a scrolling list.
    static let flatList = """
        SELECT
            \(MessageRow.selection),
            1 AS threadCount,
            (CASE WHEN m.isSeen THEN 0 ELSE 1 END) AS threadUnreadCount
        FROM message m
        WHERE m.mailboxId = :mailboxId
        ORDER BY m.sentAt DESC
        LIMIT :limit OFFSET :offset
        """

    /// The newest message of each thread, plus the thread's size and unread count.
    ///
    /// The shape matters. Walking `idxMessageMailboxSent` newest-first and asking of each row
    /// "are you the newest in your thread?" stops after `limit` matches, so the cost follows
    /// the window rather than the mailbox. A `GROUP BY threadRootId` would be correct and would
    /// visit all fifty thousand rows to return fifty.
    ///
    /// The counts are correlated subqueries, so they run for the rows that survive the window
    /// and no others — but only while the ORDER BY needs no sorter. See the note on
    /// ``flatList``: a sorter buffers every qualifying row before the LIMIT bites, which meant
    /// two counts for all ten thousand threads instead of for fifty.
    ///
    /// Both the counts and the newest-in-thread test seek `idxMessageThread`, which
    /// `MessageQueryTests.theThreadedListUsesTheThreadIndex` asserts. The unread count is a
    /// `sum` over the thread rather than a `count` with `AND c.isSeen = 0`, and that is the
    /// difference between 1 ms and 196 ms. With `isSeen` in the WHERE clause SQLite preferred
    /// `idxMessageMailboxSeen`, which matches every unread message in the mailbox and then
    /// filters by thread — sixteen thousand rows visited per list row instead of five.
    ///
    /// A NULL `threadRootId` is its own thread of one. `=` never matches NULL in SQL, so
    /// without the explicit branch every unthreaded message in the mailbox would vanish from
    /// the list.
    static let threadedList = """
        SELECT
            \(MessageRow.selection),
            CASE WHEN m.threadRootId IS NULL THEN 1 ELSE (
                SELECT count(*) FROM message c
                 WHERE c.mailboxId = :mailboxId AND c.threadRootId = m.threadRootId
            ) END AS threadCount,
            CASE WHEN m.threadRootId IS NULL THEN (CASE WHEN m.isSeen THEN 0 ELSE 1 END) ELSE (
                SELECT coalesce(sum(CASE WHEN c.isSeen THEN 0 ELSE 1 END), 0) FROM message c
                 WHERE c.mailboxId = :mailboxId AND c.threadRootId = m.threadRootId
            ) END AS threadUnreadCount
        FROM message m
        WHERE m.mailboxId = :mailboxId
          AND (
                m.threadRootId IS NULL
                OR m.id = (
                    SELECT c.id FROM message c
                     WHERE c.mailboxId = :mailboxId AND c.threadRootId = m.threadRootId
                     ORDER BY c.sentAt DESC
                     LIMIT 1
                )
              )
        ORDER BY m.sentAt DESC
        LIMIT :limit OFFSET :offset
        """

    /// One thread, oldest first.
    static let thread = """
        SELECT
            \(MessageRow.selection),
            1 AS threadCount,
            (CASE WHEN m.isSeen THEN 0 ELSE 1 END) AS threadUnreadCount
        FROM message m
        WHERE m.mailboxId = :mailboxId AND m.threadRootId = :rootId
        ORDER BY m.sentAt ASC, m.id ASC
        """
}

/// `(?, ?, ?)` for an `IN` clause of `count` values.
func databaseQuestionMarks(count: Int) -> String {
    "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
}
