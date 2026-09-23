// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import NCMailStore

/// What one queued operation does to the mirror when it is applied, reverted or dropped.
///
/// One shape for all five kinds, because the local effect of every one of them is some
/// combination of three things: set flags, change mailbox, remove the row. A move is a
/// ``mailboxId`` with no flags, a flag change is the reverse, and a delete is either a move
/// to trash or ``removesRows``.
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

    public init(
        messageIds: [Int64],
        flags: [String: Bool] = [:],
        mailboxId: Int64? = nil,
        removesRows: Bool = false
    ) {
        self.messageIds = messageIds
        self.flags = flags
        self.mailboxId = mailboxId
        self.removesRows = removesRows
    }

    var isEmpty: Bool {
        messageIds.isEmpty || (flags.isEmpty && mailboxId == nil && !removesRows)
    }
}

/// The mirror, as the mutation queue needs it.
///
/// **This protocol exists because `NCMailStore` has no queue DAO and `NCMailSync` may not
/// open a transaction of its own.** [ADR-0034](../../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)
/// made `MailStore.read`/`write` internal so that no GRDB type crosses the store's boundary,
/// which is right and is what stops a view reaching the database; the standing cost it names
/// is that "the next thing that wants a query the store does not have needs a DAO rather
/// than a closure". This is that thing, and the DAO belongs to WS-03.
/// [ADR-0043](../../../../docs/decisions/0043-the-queue-names-the-storage-it-needs.md) has
/// the argument and names the replacement.
///
/// Four of the eight methods — ``message(id:)``, ``mailbox(id:)``, ``mailboxes(accountId:)``
/// and ``account(id:)`` — already exist on `MailStore` with these exact signatures, so the
/// conformance is a declaration for those. The other four are the queue DAO.
public protocol OperationStoring: Sendable {
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
    func enqueue(_ operations: [PendingOperationRecord], applying effects: [LocalEffect]) async throws -> [Int64]

    /// Every row of `accountId`, in `id` order, whatever its state.
    func pendingOperations(accountId: Int64) async throws -> [PendingOperationRecord]

    /// Claims rows for a request, so a second drain of the same account cannot send them
    /// twice.
    func markInFlight(ids: [Int64]) async throws

    /// Returns rows to `pending` with a new attempt count and wait.
    ///
    /// - Parameter attempts: nil leaves the count alone, which is what a 429 does: the server
    ///   asked for patience, and patience is not a failure.
    func reschedule(ids: [Int64], attempts: Int?, nextAttemptAt: Int64?, lastError: String?) async throws

    /// Deletes rows and applies `effects`, in one transaction.
    ///
    /// Success passes none (the local change is already there). The 404 branch passes a row
    /// removal, and **Discard** passes the inverse of what was applied — which is several
    /// effects when a move gathered messages from several folders and each one has to go
    /// back where it came from.
    func finish(ids: [Int64], applying effects: [LocalEffect]) async throws

    func message(id: Int64) async throws -> MessageRecord?
    /// Every message of one thread within one account, oldest first.
    func threadMessages(accountId: Int64, rootId: String) async throws -> [MessageRecord]
    func mailbox(id: Int64) async throws -> MailboxRecord?
    func mailboxes(accountId: Int64) async throws -> [MailboxRecord]
    func account(id: Int64) async throws -> AccountRecord?
}
