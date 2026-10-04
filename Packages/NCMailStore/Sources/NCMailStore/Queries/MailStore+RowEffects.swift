// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import GRDB

/// One row-level change a queued operation makes to the mirror, beyond `message`'s own
/// columns. Carried in ``LocalEffect/rows`` so it lands in the same transaction as the
/// `pendingOperation` insert ([ADR-0005](../../../../docs/decisions/0005-offline-mutation-queue.md)).
///
/// Server-numbered rows are addressed by `remoteId`, never by local id, because the queue
/// records effects before it knows which local id a row will get. A negative `remoteId` is
/// a placeholder for a row the server has not created yet; the matching `replace…RemoteId`
/// case swaps in the server's id once it answers, keeping the local id and every child.
public enum RowEffect: Sendable, Equatable {
    // MARK: Tags

    /// Upsert on `(accountId, remoteId)`.
    case upsertTag(accountId: Int64, remoteId: Int64, imapLabel: String, displayName: String, color: String?)
    /// Deletes the tag; `messageTag` rows go with it.
    case deleteTag(accountId: Int64, remoteId: Int64)
    /// Swaps a tag's remote id. A non-nil `imapLabel` also replaces the label (the server
    /// may answer with one the client did not guess).
    case replaceTagRemoteId(accountId: Int64, from: Int64, to: Int64, imapLabel: String?)
    /// Links or unlinks the tag found by `(accountId, imapLabel)`; no-op when there is none.
    case setMessageTag(messageIds: [Int64], accountId: Int64, imapLabel: String, present: Bool)

    // MARK: Mailboxes

    /// Same semantics as ``MailStore/upsert(mailboxes:accountId:)``, for `write.accountId`.
    case upsertMailbox(MailboxWrite)
    /// Deletes the mailbox and every message in it.
    case deleteMailbox(accountId: Int64, remoteId: Int64)
    case replaceMailboxRemoteId(accountId: Int64, from: Int64, to: Int64)

    // MARK: Snooze

    /// Snoozes the messages until `until`; nil clears.
    case setSnooze(messageIds: [Int64], until: Int64?)

    // MARK: Account

    /// Same semantics as ``MailStore/upsert(accounts:)``.
    case upsertAccount(AccountWrite)

    // MARK: Settings

    case setPreference(loginId: Int64, key: String, value: String?, fetchedAt: Int64)
    /// Upsert on `(accountId, remoteId)`, keeping the local id.
    case upsertAlias(AliasRecord)
    case deleteAlias(accountId: Int64, remoteId: Int64)
    case replaceAliasRemoteId(accountId: Int64, from: Int64, to: Int64)
    /// Upsert on `(loginId, remoteId)`, keeping the local id and the shares.
    case upsertTextBlock(TextBlockRecord)
    case deleteTextBlock(loginId: Int64, remoteId: Int64)
    case replaceTextBlockRemoteId(loginId: Int64, from: Int64, to: Int64)
    /// Adds (upserting `displayName`) or removes the share `(type, shareWith)`.
    case setTextBlockShare(
        loginId: Int64, textBlockRemoteId: Int64, shareWith: String, type: String, displayName: String?,
        present: Bool
    )
    /// Upsert on `(accountId, remoteId)`, keeping the local id and the steps.
    case upsertQuickAction(QuickActionRecord)
    case deleteQuickAction(accountId: Int64, remoteId: Int64)
    case replaceQuickActionRemoteId(accountId: Int64, from: Int64, to: Int64)
    /// Upsert on `(quickActionId, step.remoteId)`; `step.quickActionId` is ignored. No-op
    /// when the action is absent.
    case upsertQuickActionStep(accountId: Int64, quickActionRemoteId: Int64, step: QuickActionStepRecord)
    case deleteQuickActionStep(accountId: Int64, quickActionRemoteId: Int64, stepRemoteId: Int64)
    case replaceQuickActionStepRemoteId(accountId: Int64, quickActionRemoteId: Int64, from: Int64, to: Int64)
    case setInternalAddress(loginId: Int64, address: String, type: String, present: Bool)
    case setTrustedSender(loginId: Int64, email: String, type: String, present: Bool)
    /// Writes a `meta` value; nil removes it.
    case setMeta(key: String, value: String?)
}

extension MailStore {
    /// Resolves a tag placeholder. When sync already mirrored the server's row (same
    /// `remoteId`, or the same label), the placeholder's links move onto that row and the
    /// placeholder goes; otherwise the placeholder row is renumbered in place.
    static func replaceTagRemoteId(
        accountId: Int64, from: Int64, to: Int64, imapLabel: String?, in db: Database
    ) throws {
        guard
            let placeholder = try Row.fetchOne(
                db,
                sql: "SELECT id, imapLabel FROM tag WHERE accountId = ? AND remoteId = ?",
                arguments: [accountId, from]
            )
        else { return }
        let placeholderId: Int64 = placeholder["id"]
        let label = imapLabel ?? placeholder["imapLabel"]
        let existing = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM tag
                 WHERE accountId = ? AND id != ? AND (remoteId = ? OR imapLabel = ?)
                 ORDER BY remoteId = ? DESC LIMIT 1
                """,
            arguments: [accountId, placeholderId, to, label, to]
        )
        guard let existing else {
            try db.execute(
                sql: "UPDATE tag SET remoteId = ?, imapLabel = ? WHERE id = ?",
                arguments: [to, label, placeholderId]
            )
            return
        }
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO messageTag (messageId, tagId)
                SELECT messageId, ? FROM messageTag WHERE tagId = ?
                """,
            arguments: [existing, placeholderId]
        )
        try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [placeholderId])
        // The label may still collide with a third row; the server's id wins, so drop it too.
        try db.execute(
            sql: "DELETE FROM tag WHERE accountId = ? AND imapLabel = ? AND id != ?",
            arguments: [accountId, label, existing]
        )
        try db.execute(
            sql: "UPDATE tag SET remoteId = ?, imapLabel = ? WHERE id = ?",
            arguments: [to, label, existing]
        )
    }
}

extension MailStore {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func apply(_ effect: RowEffect, in db: Database) throws {
        switch effect {
        case .upsertTag(let accountId, let remoteId, let imapLabel, let displayName, let color):
            try db.execute(
                sql: """
                    INSERT INTO tag (accountId, remoteId, imapLabel, displayName, color)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (accountId, remoteId) DO UPDATE SET
                        imapLabel = excluded.imapLabel,
                        displayName = excluded.displayName,
                        color = excluded.color
                    """,
                arguments: [accountId, remoteId, imapLabel, displayName, color]
            )
        case .deleteTag(let accountId, let remoteId):
            try db.execute(
                sql: "DELETE FROM tag WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId]
            )
        case .replaceTagRemoteId(let accountId, let from, let to, let imapLabel):
            try replaceTagRemoteId(accountId: accountId, from: from, to: to, imapLabel: imapLabel, in: db)
        case .setMessageTag(let messageIds, let accountId, let imapLabel, let present):
            guard !messageIds.isEmpty,
                let tagId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM tag WHERE accountId = ? AND imapLabel = ?",
                    arguments: [accountId, imapLabel]
                )
            else { return }
            if present {
                let link = try db.cachedStatement(
                    sql: "INSERT OR IGNORE INTO messageTag (messageId, tagId) VALUES (?, ?)"
                )
                for messageId in messageIds {
                    link.arguments = [messageId, tagId]
                    try link.execute()
                }
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM messageTag
                         WHERE tagId = ? AND messageId IN \(databaseQuestionMarks(count: messageIds.count))
                        """,
                    arguments: StatementArguments([tagId] + messageIds)
                )
            }

        case .upsertMailbox(let write):
            _ = try upsertMailbox(write, accountId: write.accountId, in: db)
        case .deleteMailbox(let accountId, let remoteId):
            try db.execute(
                sql: "DELETE FROM mailbox WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId]
            )
        case .replaceMailboxRemoteId(let accountId, let from, let to):
            try db.execute(
                sql: "UPDATE mailbox SET remoteId = ? WHERE accountId = ? AND remoteId = ?",
                arguments: [to, accountId, from]
            )

        case .setSnooze(let messageIds, let until):
            guard !messageIds.isEmpty else { return }
            if let until {
                let upsert = try db.cachedStatement(
                    sql: """
                        INSERT INTO snooze (messageId, until) VALUES (?, ?)
                        ON CONFLICT (messageId) DO UPDATE SET until = excluded.until
                        """
                )
                for messageId in messageIds {
                    upsert.arguments = [messageId, until]
                    try upsert.execute()
                }
            } else {
                try db.execute(
                    sql: "DELETE FROM snooze WHERE messageId IN \(databaseQuestionMarks(count: messageIds.count))",
                    arguments: StatementArguments(messageIds)
                )
            }

        case .upsertAccount(let write):
            _ = try write.upsertAndFetch(db, as: AccountRecord.self)

        case .setPreference(let loginId, let key, let value, let fetchedAt):
            var row = PreferenceRecord(loginId: loginId, key: key, value: value, fetchedAt: fetchedAt)
            try row.upsert(db)
        case .upsertAlias(let alias):
            try db.execute(
                sql: """
                    INSERT INTO alias
                        (accountId, remoteId, email, name, signature, provisioned, smimeCertificateRemoteId, rawJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (accountId, remoteId) DO UPDATE SET
                        email = excluded.email,
                        name = excluded.name,
                        signature = excluded.signature,
                        provisioned = excluded.provisioned,
                        smimeCertificateRemoteId = excluded.smimeCertificateRemoteId,
                        rawJSON = excluded.rawJSON
                    """,
                arguments: [
                    alias.accountId, alias.remoteId, alias.email, alias.name, alias.signature, alias.provisioned,
                    alias.smimeCertificateRemoteId, alias.rawJSON,
                ]
            )
        case .deleteAlias(let accountId, let remoteId):
            try db.execute(
                sql: "DELETE FROM alias WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId]
            )
        case .replaceAliasRemoteId(let accountId, let from, let to):
            try db.execute(
                sql: "UPDATE alias SET remoteId = ? WHERE accountId = ? AND remoteId = ?",
                arguments: [to, accountId, from]
            )
        case .upsertTextBlock(let block):
            try db.execute(
                sql: """
                    INSERT INTO textBlock (loginId, remoteId, title, content, isShared, ownerId, rawJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (loginId, remoteId) DO UPDATE SET
                        title = excluded.title,
                        content = excluded.content,
                        isShared = excluded.isShared,
                        ownerId = excluded.ownerId,
                        rawJSON = excluded.rawJSON
                    """,
                arguments: [
                    block.loginId, block.remoteId, block.title, block.content, block.isShared, block.ownerId,
                    block.rawJSON,
                ]
            )
        case .deleteTextBlock(let loginId, let remoteId):
            try db.execute(
                sql: "DELETE FROM textBlock WHERE loginId = ? AND remoteId = ?", arguments: [loginId, remoteId]
            )
        case .replaceTextBlockRemoteId(let loginId, let from, let to):
            try db.execute(
                sql: "UPDATE textBlock SET remoteId = ? WHERE loginId = ? AND remoteId = ?",
                arguments: [to, loginId, from]
            )
        case .setTextBlockShare(
            let loginId, let textBlockRemoteId, let shareWith, let type, let displayName, let present):
            guard
                let blockId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM textBlock WHERE loginId = ? AND remoteId = ?",
                    arguments: [loginId, textBlockRemoteId]
                )
            else { return }
            if present {
                try db.execute(
                    sql: """
                        INSERT INTO textBlockShare (textBlockId, shareWith, type, displayName, rawJSON)
                        VALUES (?, ?, ?, ?, '{}')
                        ON CONFLICT (textBlockId, type, shareWith) DO UPDATE SET
                            displayName = excluded.displayName
                        """,
                    arguments: [blockId, shareWith, type, displayName]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM textBlockShare WHERE textBlockId = ? AND type = ? AND shareWith = ?",
                    arguments: [blockId, type, shareWith]
                )
            }
        case .upsertQuickAction(let action):
            try db.execute(
                sql: """
                    INSERT INTO quickAction (accountId, remoteId, name, rawJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT (accountId, remoteId) DO UPDATE SET
                        name = excluded.name,
                        rawJSON = excluded.rawJSON
                    """,
                arguments: [action.accountId, action.remoteId, action.name, action.rawJSON]
            )
        case .deleteQuickAction(let accountId, let remoteId):
            try db.execute(
                sql: "DELETE FROM quickAction WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId]
            )
        case .replaceQuickActionRemoteId(let accountId, let from, let to):
            try db.execute(
                sql: "UPDATE quickAction SET remoteId = ? WHERE accountId = ? AND remoteId = ?",
                arguments: [to, accountId, from]
            )
        case .upsertQuickActionStep(let accountId, let quickActionRemoteId, let step):
            try db.execute(
                sql: """
                    INSERT INTO quickActionStep
                        (quickActionId, remoteId, name, position, tagRemoteId, mailboxRemoteId, rawJSON)
                    SELECT id, ?, ?, ?, ?, ?, ? FROM quickAction WHERE accountId = ? AND remoteId = ?
                    ON CONFLICT (quickActionId, remoteId) DO UPDATE SET
                        name = excluded.name,
                        position = excluded.position,
                        tagRemoteId = excluded.tagRemoteId,
                        mailboxRemoteId = excluded.mailboxRemoteId,
                        rawJSON = excluded.rawJSON
                    """,
                arguments: [
                    step.remoteId, step.name, step.position, step.tagRemoteId, step.mailboxRemoteId, step.rawJSON,
                    accountId, quickActionRemoteId,
                ]
            )
        case .deleteQuickActionStep(let accountId, let quickActionRemoteId, let stepRemoteId):
            try db.execute(
                sql: """
                    DELETE FROM quickActionStep
                     WHERE remoteId = ?
                       AND quickActionId = (SELECT id FROM quickAction WHERE accountId = ? AND remoteId = ?)
                    """,
                arguments: [stepRemoteId, accountId, quickActionRemoteId]
            )
        case .replaceQuickActionStepRemoteId(let accountId, let quickActionRemoteId, let from, let to):
            try db.execute(
                sql: """
                    UPDATE quickActionStep SET remoteId = ?
                     WHERE remoteId = ?
                       AND quickActionId = (SELECT id FROM quickAction WHERE accountId = ? AND remoteId = ?)
                    """,
                arguments: [to, from, accountId, quickActionRemoteId]
            )
        case .setInternalAddress(let loginId, let address, let type, let present):
            try db.execute(
                sql: present
                    ? "INSERT OR IGNORE INTO internalAddress (loginId, address, type) VALUES (?, ?, ?)"
                    : "DELETE FROM internalAddress WHERE loginId = ? AND address = ? AND type = ?",
                arguments: [loginId, address, type]
            )
        case .setTrustedSender(let loginId, let email, let type, let present):
            try db.execute(
                sql: present
                    ? "INSERT OR IGNORE INTO trustedSender (loginId, email, type) VALUES (?, ?, ?)"
                    : "DELETE FROM trustedSender WHERE loginId = ? AND email = ? AND type = ?",
                arguments: [loginId, email, type]
            )
        case .setMeta(let key, let value):
            if let value {
                try MetaRecord(key: key, value: value).upsert(db)
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }
}

// MARK: - Snapshot reads

extension MailStore {
    /// Each message's tag labels, sorted. Messages without tags are absent from the map.
    /// What the queue records as "before" for a tag change.
    public func messageTagLabels(messageIds: [Int64]) async throws -> [Int64: [String]] {
        guard !messageIds.isEmpty else { return [:] }
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT messageTag.messageId AS messageId, tag.imapLabel AS label
                      FROM messageTag JOIN tag ON tag.id = messageTag.tagId
                     WHERE messageTag.messageId IN \(databaseQuestionMarks(count: messageIds.count))
                     ORDER BY messageTag.messageId, tag.imapLabel
                    """,
                arguments: StatementArguments(messageIds)
            )
            return rows.reduce(into: [:]) { result, row in
                result[row["messageId"] as Int64, default: []].append(row["label"] as String)
            }
        }
    }

    public func alias(accountId: Int64, remoteId: Int64) async throws -> AliasRecord? {
        try await dbQueue.read { db in
            try AliasRecord.fetchOne(
                db,
                sql: "SELECT * FROM alias WHERE accountId = ? AND remoteId = ?",
                arguments: [accountId, remoteId]
            )
        }
    }

    public func textBlock(loginId: Int64, remoteId: Int64) async throws -> TextBlockRecord? {
        try await dbQueue.read { db in
            try TextBlockRecord.fetchOne(
                db,
                sql: "SELECT * FROM textBlock WHERE loginId = ? AND remoteId = ?",
                arguments: [loginId, remoteId]
            )
        }
    }

    public func quickAction(accountId: Int64, remoteId: Int64) async throws -> QuickActionRecord? {
        try await dbQueue.read { db in
            try QuickActionRecord.fetchOne(
                db,
                sql: "SELECT * FROM quickAction WHERE accountId = ? AND remoteId = ?",
                arguments: [accountId, remoteId]
            )
        }
    }

    /// Every message id in one mailbox, ascending.
    public func messageIds(mailboxId: Int64) async throws -> [Int64] {
        try await dbQueue.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT id FROM message WHERE mailboxId = ? ORDER BY id", arguments: [mailboxId]
            )
        }
    }

    /// The unread message ids in one mailbox, ascending.
    public func unreadMessageIds(mailboxId: Int64) async throws -> [Int64] {
        try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM message WHERE mailboxId = ? AND isSeen = 0 ORDER BY id",
                arguments: [mailboxId]
            )
        }
    }
}
