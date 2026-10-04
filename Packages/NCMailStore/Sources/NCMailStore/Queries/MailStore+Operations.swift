// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

/// What one queued operation does to the mirror when it is applied, reverted or dropped.
///
/// One shape for every kind, because the local effect of each is some combination of four
/// things: set flags, change mailbox, remove the row, set a sender's image trust. A move is a
/// ``mailboxId`` with no flags, a flag change is the reverse, a delete is either a move to
/// trash or ``removesRows``, and a sender trust is ``senderTrust`` with no rows at all.
///
/// It lives here rather than in `NCMailSync` because ``MailStore/enqueue(_:applying:)`` and
/// ``MailStore/finish(ids:applying:)`` take it, and a store method cannot name a type from a
/// module above it.
public struct LocalEffect: Sendable, Equatable {
    /// Local `message.id`s. Thread operations resolve their members before the write, so by
    /// the time an effect exists it is always a list of rows.
    public var messageIds: [Int64]
    /// Absolute values for the columns these keys name. Keys with no column are ignored.
    public var flags: [String: Bool]
    /// Local `mailbox.id` to move the rows into.
    public var mailboxId: Int64?
    /// Deletes the rows outright. The erase branch of `delete`, and the 404 branch of the
    /// drain.
    public var removesRows: Bool
    /// Trust (or distrust) every stored body from one sender in one account, matched by
    /// address rather than by row so the local effect reaches every message the mirror holds
    /// from them at commit time, not only the ones the caller happened to read first.
    public var senderTrust: SenderTrust?
    /// `messageBody.isSenderTrusted` for exactly ``messageIds``. Discard's half of a sender
    /// trust: putting each body back to what it held, which is not one value for all of them.
    public var isSenderTrusted: Bool?
    /// Row-level changes outside `message`'s own columns — tags, mailboxes, settings —
    /// applied in order, after the message part, in the same transaction.
    public var rows: [RowEffect]

    public init(
        messageIds: [Int64],
        flags: [String: Bool] = [:],
        mailboxId: Int64? = nil,
        removesRows: Bool = false,
        senderTrust: SenderTrust? = nil,
        isSenderTrusted: Bool? = nil,
        rows: [RowEffect] = []
    ) {
        self.messageIds = messageIds
        self.flags = flags
        self.mailboxId = mailboxId
        self.removesRows = removesRows
        self.senderTrust = senderTrust
        self.isSenderTrusted = isSenderTrusted
        self.rows = rows
    }
}

/// One sender's image trust, as ``LocalEffect/senderTrust`` applies it.
public struct SenderTrust: Sendable, Equatable {
    public var accountId: Int64
    /// Compared case-insensitively against `message.fromEmail`: the server treats addresses
    /// that way, and a sender who capitalises differently is still the same sender.
    public var email: String
    public var trusted: Bool

    public init(accountId: Int64, email: String, trusted: Bool) {
        self.accountId = accountId
        self.email = email
        self.trusted = trusted
    }
}

/// The flag setter's key spellings, against the mirror's column names.
///
/// The same mapping `SyncConflicts` applies in the other direction. It is here because the
/// UPDATE below looks column names up rather than interpolating them from a payload, and
/// because the queue has to read a column to record what it is about to overwrite.
public enum MessageFlagColumns {
    public static func value(of key: String, in message: MessageRecord) -> Bool {
        switch key {
        case "seen": message.isSeen
        case "flagged": message.isFlagged
        case "answered": message.isAnswered
        case "deleted": message.isDeleted
        case "draft": message.isDraft
        case "forwarded": message.isForwarded
        case "important": message.isImportant
        case "junk": message.isJunk
        case "notjunk": message.isNotJunk
        case "mdnsent": message.isMdnSent
        // An IMAP keyword the mirror has no column for. The setter accepts any, so the queue
        // carries it to the server and records "false" as the state to revert to, which is
        // what a column that does not exist holds.
        default: false
        }
    }

    /// Column names for the keys the mirror stores.
    public static func column(for key: String) -> String? {
        switch key {
        case "seen": "isSeen"
        case "flagged": "isFlagged"
        case "answered": "isAnswered"
        case "deleted": "isDeleted"
        case "draft": "isDraft"
        case "forwarded": "isForwarded"
        case "important": "isImportant"
        case "junk": "isJunk"
        case "notjunk": "isNotJunk"
        case "mdnsent": "isMdnSent"
        default: nil
        }
    }
}

/// The offline mutation queue's storage.
///
/// These are the methods `MutationQueue` and `OperationDrainer` call. They were written and
/// tested in `NCMailSync`'s test target against a protocol, because `read` and `write` went
/// internal with [ADR-0034](../../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)
/// and there was no DAO over `pendingOperation`
/// ([ADR-0043](../../../../docs/decisions/0043-the-queue-names-the-storage-it-needs.md)).
/// This is that DAO, and the protocol is gone.
extension MailStore {
    /// Applies every effect and inserts every row, in **one** transaction. Both or neither.
    ///
    /// This is the whole of [ADR-0005](../../../../docs/decisions/0005-offline-mutation-queue.md):
    /// there must be no instant in which the list says archived and nothing remembers to tell
    /// the server, and none in which a row is queued for a change the user cannot see.
    ///
    /// - Parameters:
    ///   - operations: rows to insert, in the order they must be sent.
    ///   - effects: the local change each row describes, in the same order.
    /// - Returns: the inserted rows' ids, in order.
    @discardableResult
    public func enqueue(
        _ operations: [PendingOperationRecord],
        applying effects: [LocalEffect]
    ) async throws -> [Int64] {
        try await dbQueue.write { db in
            var ids: [Int64] = []
            for (index, operation) in operations.enumerated() {
                if index < effects.count { try Self.apply(effects[index], in: db) }
                var row = operation
                try row.insert(db)
                if let id = row.id { ids.append(id) }
            }
            return ids
        }
    }

    /// Every row of `accountId`, in `id` order, whatever its state.
    public func pendingOperations(accountId: Int64) async throws -> [PendingOperationRecord] {
        try await dbQueue.read { db in
            try PendingOperationRecord.fetchAll(
                db,
                sql: "SELECT * FROM pendingOperation WHERE accountId = ? ORDER BY id",
                arguments: [accountId]
            )
        }
    }

    /// Claims rows for a request, so a second drain of the same account cannot send them
    /// twice.
    public func markInFlight(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE pendingOperation SET state = 'inFlight'
                     WHERE id IN \(databaseQuestionMarks(count: ids.count))
                    """,
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Returns rows to `pending` with a new attempt count and wait.
    ///
    /// - Parameter attempts: nil leaves the count alone, which is what a 429 does: the server
    ///   asked for patience, and patience is not a failure.
    public func reschedule(
        ids: [Int64],
        attempts: Int?,
        nextAttemptAt: Int64?,
        lastError: String?
    ) async throws {
        guard !ids.isEmpty else { return }
        try await dbQueue.write { db in
            let arguments: [(any DatabaseValueConvertible)?] =
                [attempts, nextAttemptAt, lastError] + ids.map { $0 as (any DatabaseValueConvertible)? }
            try db.execute(
                sql: """
                    UPDATE pendingOperation
                       SET state = 'pending',
                           attempts = coalesce(?, attempts),
                           nextAttemptAt = ?,
                           lastError = ?
                     WHERE id IN \(databaseQuestionMarks(count: ids.count))
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Deletes rows and applies `effects`, in one transaction.
    ///
    /// Success passes none (the local change is already there). The 404 branch passes a row
    /// removal, and **Discard** passes the inverse of what was applied — which is several
    /// effects when a move gathered messages from several folders and each one has to go
    /// back where it came from.
    public func finish(ids: [Int64], applying effects: [LocalEffect]) async throws {
        try await dbQueue.write { db in
            for effect in effects { try Self.apply(effect, in: db) }
            guard !ids.isEmpty else { return }
            try db.execute(
                sql: "DELETE FROM pendingOperation WHERE id IN \(databaseQuestionMarks(count: ids.count))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Every message of one thread within one account, oldest first.
    ///
    /// Account-wide rather than per mailbox, because a thread operation acts on every copy of
    /// the conversation the mirror holds, wherever it sits.
    public func threadMessages(accountId: Int64, rootId: String) async throws -> [MessageRecord] {
        try await dbQueue.read { db in
            try MessageRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM message
                     WHERE accountId = ? AND threadRootId = ?
                     ORDER BY sentAt ASC, id ASC
                    """,
                arguments: [accountId, rootId]
            )
        }
    }

    /// `messageBody.isSenderTrusted` for every stored body from `email` in `accountId`, keyed
    /// by local message id. What a sender-trust operation records as its "before", so Discard
    /// can put each body back.
    public func senderTrustStates(accountId: Int64, email: String) async throws -> [Int64: Bool] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.messageId AS messageId, b.isSenderTrusted AS trusted
                      FROM messageBody b JOIN message m ON m.id = b.messageId
                     WHERE m.accountId = ? AND lower(m.fromEmail) = lower(?)
                    """,
                arguments: [accountId, email]
            )
            return rows.reduce(into: [:]) { result, row in
                result[row["messageId"] as Int64] = row["trusted"] as Bool
            }
        }
    }

    /// One local effect, as SQL. Column names are looked up rather than interpolated from the
    /// payload, so a key nobody modelled cannot reach the statement.
    private static func apply(_ effect: LocalEffect, in db: Database) throws {
        for row in effect.rows { try apply(row, in: db) }
        try applyMessagePart(effect, in: db)
    }

    private static func applyMessagePart(_ effect: LocalEffect, in db: Database) throws {
        if let trust = effect.senderTrust {
            try db.execute(
                sql: """
                    UPDATE messageBody SET isSenderTrusted = ?
                     WHERE messageId IN (
                        SELECT id FROM message WHERE accountId = ? AND lower(fromEmail) = lower(?)
                     )
                    """,
                arguments: [trust.trusted, trust.accountId, trust.email]
            )
        }
        guard !effect.messageIds.isEmpty else { return }
        let placeholders = databaseQuestionMarks(count: effect.messageIds.count)

        if let trusted = effect.isSenderTrusted {
            let values: [(any DatabaseValueConvertible)?] =
                [trusted] + effect.messageIds.map { $0 as (any DatabaseValueConvertible)? }
            try db.execute(
                sql: "UPDATE messageBody SET isSenderTrusted = ? WHERE messageId IN \(placeholders)",
                arguments: StatementArguments(values)
            )
        }

        if effect.removesRows {
            try db.execute(
                sql: "DELETE FROM message WHERE id IN \(placeholders)",
                arguments: StatementArguments(effect.messageIds)
            )
            return
        }

        var assignments: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []
        for key in effect.flags.keys.sorted() {
            guard let column = MessageFlagColumns.column(for: key) else { continue }
            assignments.append("\(column) = ?")
            values.append(effect.flags[key])
        }
        if let mailboxId = effect.mailboxId {
            assignments.append("mailboxId = ?")
            values.append(mailboxId)
        }
        guard !assignments.isEmpty else { return }
        values.append(contentsOf: effect.messageIds.map { $0 as (any DatabaseValueConvertible)? })
        try db.execute(
            sql: "UPDATE message SET \(assignments.joined(separator: ", ")) WHERE id IN \(placeholders)",
            arguments: StatementArguments(values)
        )
    }
}
