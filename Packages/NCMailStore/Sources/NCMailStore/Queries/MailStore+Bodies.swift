// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
import GRDB

extension MailStore {
    /// Stores a backfilled body: the body row, its attachments' metadata, the `body` column of
    /// the search index, and the message's `bodyState`, in one transaction.
    ///
    /// Four writes that have to land together. A body present with `bodyState = 'missing'`
    /// would be re-fetched forever; `bodyState = 'present'` with no body row would render an
    /// empty message and never correct itself.
    public func upsert(body: MessageBodyWrite, for messageId: Int64) async throws {
        let indexedText = body.indexedText
        let byteSize = Int64((body.html?.utf8.count ?? 0) + (body.plainBody?.utf8.count ?? 0))

        try await dbQueue.write { db in
            try MessageBodyRecord(
                messageId: messageId,
                hasHtmlBody: body.hasHtmlBody,
                html: body.html,
                plainBody: body.plainBody,
                signature: body.signature,
                isSenderTrusted: body.isSenderTrusted,
                dkimValid: body.dkimValid,
                smimeJSON: body.smimeJSON,
                phishingJSON: body.phishingJSON,
                schedulingJSON: body.schedulingJSON,
                itinerariesJSON: body.itinerariesJSON,
                unsubscribeUrl: body.unsubscribeUrl,
                unsubscribeMailto: body.unsubscribeMailto,
                isOneClickUnsubscribe: body.isOneClickUnsubscribe,
                dispositionNotificationTo: body.dispositionNotificationTo,
                hasAiGeneratedHeader: body.hasAiGeneratedHeader,
                fetchedAt: body.fetchedAt,
                byteSize: byteSize,
                sanitiserGeneration: body.sanitiserGeneration,
                rawJSON: body.rawJSON
            ).upsert(db)

            for attachment in body.attachments {
                try AttachmentRecord(
                    messageId: messageId,
                    attachmentId: attachment.attachmentId,
                    isInline: attachment.isInline,
                    fileName: attachment.fileName,
                    mime: attachment.mime,
                    size: attachment.size,
                    cid: attachment.cid,
                    disposition: attachment.disposition,
                    isImage: attachment.isImage,
                    isCalendarEvent: attachment.isCalendarEvent,
                    downloadUrl: attachment.downloadUrl,
                    data: nil,
                    fetchedAt: nil
                ).upsert(db)
            }

            try SearchIndexWriter.indexBody(messageId: messageId, text: indexedText, in: db)
            try db.execute(
                sql: "UPDATE message SET bodyState = 'present' WHERE id = ?",
                arguments: [messageId]
            )
        }
    }

    /// The body and its attachments, from one read.
    public func body(messageId: Int64) async throws -> StoredBody? {
        try await dbQueue.read { db in try Self.fetchBody(db, messageId: messageId) }
    }

    /// One message's body and attachments, live.
    ///
    /// This is what the message view opens when it shows a message whose body the backfill
    /// has not reached: the fetch writes the database, and the value arrives here. It fires
    /// when the body lands because ``upsert(body:for:)`` writes the body row, the
    /// attachments and `message.bodyState` in one transaction, and both tables this reads
    /// are inside it.
    ///
    /// Nil while there is no body row, which is the ordinary state of a message the mirror
    /// has the envelope for and nothing else.
    public func observeBody(messageId: Int64) -> StoreObservation<StoredBody?> {
        observation { db in try Self.fetchBody(db, messageId: messageId) }
    }

    private static func fetchBody(_ db: Database, messageId: Int64) throws -> StoredBody? {
        guard
            let body = try MessageBodyRecord.fetchOne(
                db,
                sql: "SELECT * FROM messageBody WHERE messageId = ?",
                arguments: [messageId]
            )
        else { return nil }
        let attachments = try AttachmentRecord.fetchAll(
            db,
            sql: "SELECT * FROM attachment WHERE messageId = ? ORDER BY attachmentId",
            arguments: [messageId]
        )
        return StoredBody(body: body, attachments: attachments)
    }

    /// Marks where a body got to, so a crash does not leave work claimed forever.
    public func setBodyState(_ state: BodyState, messageIds: [Int64]) async throws {
        guard !messageIds.isEmpty else { return }
        let sql = """
            UPDATE message SET bodyState = ?
             WHERE id IN \(databaseQuestionMarks(count: messageIds.count))
            """
        try await dbQueue.write { db in
            var arguments = StatementArguments([state.rawValue])
            arguments += StatementArguments(messageIds)
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    /// Keeps an inline image the renderer pulled, so the message shows its own pictures the
    /// next time it is opened offline.
    public func storeInlineAttachment(
        messageId: Int64,
        attachmentId: String,
        data: Data,
        fetchedAt: Int64
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET data = :data, fetchedAt = :fetchedAt
                     WHERE messageId = :messageId AND attachmentId = :attachmentId
                    """,
                arguments: [
                    "data": data, "fetchedAt": fetchedAt,
                    "messageId": messageId, "attachmentId": attachmentId,
                ]
            )
        }
    }
}
