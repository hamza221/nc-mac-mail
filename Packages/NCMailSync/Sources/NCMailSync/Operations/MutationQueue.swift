// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailStore

/// The front door for every triage action in the application.
///
/// One method matters, and it does one thing: **apply the change to the mirror and append
/// the promise to tell the server, in a single transaction.** Nothing between the two, no
/// request, no await. Both halves commit or neither does, so there is no instant in which
/// the list says archived and nothing remembers to tell the server, and none in which an
/// operation is queued for a change the user cannot see
/// ([ADR-0005](../../../../docs/decisions/0005-offline-mutation-queue.md)).
///
/// Online and offline are the same code path. Offline is not a mode; it is
/// ``OperationDrainer`` having nowhere to send things yet.
///
/// The return is `Void`, like everything else in this package. The list updates because the
/// database changed and the observation fired, not because this method answered — which is
/// `CLAUDE.md`'s one invariant, at the one place a view is most tempted to break it.
public actor MutationQueue {
    private let store: any OperationStoring
    private let configuration: MutationQueueConfiguration
    /// Woken after each commit. Optional so a test can watch the queue fill without anything
    /// draining it, which is exactly the offline case.
    private let drainer: OperationDrainer?

    public init(
        store: any OperationStoring,
        drainer: OperationDrainer? = nil,
        configuration: MutationQueueConfiguration = MutationQueueConfiguration()
    ) {
        self.store = store
        self.drainer = drainer
        self.configuration = configuration
    }

    /// Applies `operation` locally and enqueues it, in one transaction, then wakes the
    /// drainer.
    ///
    /// A multi-message action is one transaction and several rows: ten archived messages are
    /// ten requests, because the server has no batch route, but they land locally together or
    /// not at all.
    ///
    /// - Throws: ``OperationError/accountNotMirrored(accountId:)`` when there is no such
    ///   account, and ``OperationError/noSuchMessages`` when every id named has already gone
    ///   from the mirror — in which case nothing is queued, because there is no local change
    ///   to describe and a request would only earn a 404.
    public func perform(_ operation: MailOperation, accountId: Int64) async throws {
        guard try await store.account(id: accountId) != nil else {
            throw OperationError.accountNotMirrored(accountId: accountId)
        }
        let units = try await units(for: operation, accountId: accountId)
        guard !units.isEmpty else { throw OperationError.noSuchMessages }

        try await store.enqueue(units.map(\.record), applying: units.map(\.effect))
        OperationLog.queue.info(
            """
            account \(accountId, privacy: .public) queued \(units.count, privacy: .public) \
            \(units.first?.record.kind ?? "?", privacy: .public) operation(s)
            """
        )
        await drainer?.wake()
    }

    /// The mirror's id for one of the three mailboxes a triage action names by role.
    ///
    /// **This is the only correct way to resolve one.** `account.archiveMailboxId` and its
    /// siblings hold the *server's* numbers — they are copied straight out of the accounts
    /// payload and, unlike every other server-numbered value in the mirror, they are not
    /// spelled `remoteId` (ADR-0033). Writing one into `message.mailboxId` puts the message
    /// in whichever local mailbox happens to share that number.
    ///
    /// - Returns: nil when the account has no such role, or when the mailbox it names is not
    ///   mirrored. A live server with no archive folder configured is the common case, not a
    ///   rare one, so callers must handle nil rather than assume it.
    public func localMailboxId(for special: SpecialMailbox, accountId: Int64) async throws -> Int64? {
        guard let account = try await store.account(id: accountId) else {
            throw OperationError.accountNotMirrored(accountId: accountId)
        }
        let remoteId: Int64? =
            switch special {
            case .archive: account.archiveMailboxId
            case .junk: account.junkMailboxId
            case .trash: account.trashMailboxId
            }
        guard let remoteId else { return nil }
        return try await store.mailboxes(accountId: accountId).first { $0.remoteId == remoteId }?.id
    }

    // MARK: - Building the rows

    /// A row and the local change it describes, which only ever travel together.
    private struct Unit {
        var record: PendingOperationRecord
        var effect: LocalEffect
    }

    private func units(for operation: MailOperation, accountId: Int64) async throws -> [Unit] {
        switch operation {
        case .setFlags(let messageIds, let flags):
            return try await messageUnits(messageIds, accountId: accountId) { message in
                self.flagUnit(message, accountId: accountId, flags: flags)
            }

        case .move(let messageIds, let destinationMailboxId):
            return try await messageUnits(messageIds, accountId: accountId) { message in
                self.moveUnit(message, accountId: accountId, destination: destinationMailboxId, kind: .move)
            }

        case .delete(let messageIds):
            let trashId = try await localMailboxId(for: .trash, accountId: accountId)
            return try await messageUnits(messageIds, accountId: accountId) { message in
                self.deleteUnit(message, accountId: accountId, trashId: trashId)
            }

        case .junk(let messageIds, let junkMailboxId):
            // Flags then move, in that order and as two rows, because they are two requests
            // and the server rejects the move of a message it has not been told is junk.
            let flags = try await messageUnits(messageIds, accountId: accountId) { message in
                self.flagUnit(message, accountId: accountId, flags: ["junk": true, "notjunk": false])
            }
            let moves = try await messageUnits(messageIds, accountId: accountId) { message in
                self.moveUnit(message, accountId: accountId, destination: junkMailboxId, kind: .move)
            }
            return flags + moves

        case .moveThread(let rootId, let destinationMailboxId):
            return try await threadUnit(
                rootId: rootId,
                accountId: accountId,
                kind: .moveThread,
                destination: destinationMailboxId,
                removesRows: false
            )

        case .deleteThread(let rootId):
            let trashId = try await localMailboxId(for: .trash, accountId: accountId)
            return try await threadUnit(
                rootId: rootId,
                accountId: accountId,
                kind: .deleteThread,
                destination: trashId,
                removesRows: trashId == nil
            )
        }
    }

    /// Reads each message that still exists and turns it into a unit. An id the mirror has
    /// already lost is skipped rather than queued: the local change would be a no-op and the
    /// request a guaranteed 404.
    private func messageUnits(
        _ messageIds: [Int64],
        accountId: Int64,
        _ build: (MessageRecord) throws -> Unit
    ) async throws -> [Unit] {
        var units: [Unit] = []
        for messageId in messageIds {
            guard let message = try await store.message(id: messageId), message.accountId == accountId else {
                continue
            }
            units.append(try build(message))
        }
        return units
    }

    private func flagUnit(_ message: MessageRecord, accountId: Int64, flags: [String: Bool]) -> Unit {
        var payload = OperationPayload(flags: flags)
        payload.before = OperationSnapshot(
            messageIds: [message.id],
            flags: flags.keys.reduce(into: [:]) { result, key in
                result[key] = MessageFlagColumns.value(of: key, in: message)
            }
        )
        return Unit(
            record: record(kind: .setFlags, accountId: accountId, message: message, payload: payload),
            effect: LocalEffect(messageIds: [message.id], flags: flags)
        )
    }

    private func moveUnit(
        _ message: MessageRecord,
        accountId: Int64,
        destination: Int64,
        kind: OperationKind
    ) -> Unit {
        var payload = OperationPayload(destinationMailboxId: destination)
        payload.before = OperationSnapshot(
            messageIds: [message.id],
            mailboxIds: [message.id: message.mailboxId]
        )
        var row = record(kind: kind, accountId: accountId, message: message, payload: payload)
        row.mailboxId = destination
        return Unit(record: row, effect: LocalEffect(messageIds: [message.id], mailboxId: destination))
    }

    /// Trash, or an erase when the message is already there — `offline-queue.md`'s rule, and
    /// the server's own behaviour for `DELETE /api/messages/{id}`.
    ///
    /// An account with no mirrored trash mailbox erases locally too. That is the only
    /// answer that leaves the screen agreeing with what the server is about to do.
    private func deleteUnit(_ message: MessageRecord, accountId: Int64, trashId: Int64?) -> Unit {
        let erases = trashId == nil || trashId == message.mailboxId
        var payload = OperationPayload(destinationMailboxId: erases ? nil : trashId, erases: erases)
        payload.before = OperationSnapshot(
            messageIds: [message.id],
            mailboxIds: [message.id: message.mailboxId]
        )
        var row = record(kind: .delete, accountId: accountId, message: message, payload: payload)
        row.mailboxId = erases ? nil : trashId
        return Unit(
            record: row,
            effect: LocalEffect(
                messageIds: [message.id],
                mailboxId: erases ? nil : trashId,
                removesRows: erases
            )
        )
    }

    private func threadUnit(
        rootId: String,
        accountId: Int64,
        kind: OperationKind,
        destination: Int64?,
        removesRows: Bool
    ) async throws -> [Unit] {
        let members = try await store.threadMessages(accountId: accountId, rootId: rootId)
        // The anchor is any member: `POST /api/thread/{id}` and `DELETE /api/thread/{id}`
        // take a message id and resolve the root themselves.
        guard let anchor = members.first else { return [] }

        var payload = OperationPayload(destinationMailboxId: destination, erases: removesRows)
        payload.before = OperationSnapshot(
            messageIds: members.map(\.id),
            mailboxIds: Dictionary(members.map { ($0.id, $0.mailboxId) }, uniquingKeysWith: { first, _ in first })
        )
        var row = record(kind: kind, accountId: accountId, message: anchor, payload: payload)
        row.threadRootId = rootId
        row.mailboxId = destination
        row.baseSyncedAt = members.map(\.syncedAt).min() ?? anchor.syncedAt
        return [
            Unit(
                record: row,
                effect: LocalEffect(
                    messageIds: members.map(\.id),
                    mailboxId: removesRows ? nil : destination,
                    removesRows: removesRows
                )
            )
        ]
    }

    private func record(
        kind: OperationKind,
        accountId: Int64,
        message: MessageRecord,
        payload: OperationPayload
    ) -> PendingOperationRecord {
        var payload = payload
        payload.remoteId = message.remoteId
        return PendingOperationRecord(
            kind: kind.rawValue,
            accountId: accountId,
            messageId: message.id,
            payloadJSON: (try? payload.encoded()) ?? "{}",
            createdAt: configuration.now(),
            // `message.syncedAt` as it was when the user acted, so the drainer can tell a
            // conflict from a no-op without asking the server twice.
            baseSyncedAt: message.syncedAt
        )
    }
}

/// The flag setter's key spellings, against the mirror's column names.
///
/// The same mapping `SyncConflicts` applies in the other direction. It lives here as well
/// because the queue has to read a column to record what it is about to overwrite, and
/// `Sync/**` belongs to another workstream.
enum MessageFlagColumns {
    static func value(of key: String, in message: MessageRecord) -> Bool {
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

    /// Column names for the keys the mirror stores, for the store's own UPDATE.
    static func column(for key: String) -> String? {
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
