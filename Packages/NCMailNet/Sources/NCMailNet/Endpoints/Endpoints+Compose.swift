// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// Drafts, the outbox and composer attachment uploads. Drafts and outbox
// messages are the server's `LocalMessage` entity; every route here answers it
// inside the `JSONEnvelope` (verified live on draft create).

// MARK: - Drafts

extension Endpoint where Response == JSONEnvelope<RawBacked<LocalMessage>> {
    /// `POST /api/drafts` — HTTP 201 with the stored draft.
    public static var createDraft: Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(name: "createDraft", method: .post, encodedPath: "drafts", isRetryable: false)
    }

    /// `PUT /api/drafts/{id}`.
    public static func updateDraft(id: Int) -> Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(name: "updateDraft", method: .put, encodedPath: "drafts/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/drafts/{id}` — answers HTTP 202 with
    /// `{"status":"success","data":"Message deleted"}` (verified live); the
    /// string payload is nothing to read, so `EmptyResponse`.
    public static func deleteDraft(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteDraft", method: .delete, encodedPath: "drafts/\(id)", isRetryable: false)
    }

    /// `POST /api/drafts/move/{id}` — flushes the local draft to the IMAP
    /// drafts folder now instead of at the next background job.
    public static func moveDraftToIMAP(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "moveDraftToImap", method: .post, encodedPath: "drafts/move/\(id)", isRetryable: false)
    }
}

// MARK: - Outbox

extension Endpoint where Response == JSONEnvelope<OutboxMessages> {
    /// `GET /api/outbox` — `{"status":"success","data":{"messages":[…]}}`
    /// (verified live).
    public static var outbox: Endpoint<JSONEnvelope<OutboxMessages>> {
        Endpoint(name: "outbox", method: .get, encodedPath: "outbox", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<RawBacked<LocalMessage>> {
    /// `GET /api/outbox/{id}`.
    public static func outboxMessage(id: Int) -> Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(name: "outboxMessage", method: .get, encodedPath: "outbox/\(id)", isRetryable: true)
    }

    /// `POST /api/outbox` — queues a message; `sendAt` schedules it.
    public static var enqueueMessage: Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(name: "enqueueMessage", method: .post, encodedPath: "outbox", isRetryable: false)
    }

    /// `PUT /api/outbox/{id}`.
    public static func updateOutboxMessage(id: Int) -> Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(name: "updateOutboxMessage", method: .put, encodedPath: "outbox/\(id)", isRetryable: false)
    }

    /// `POST /api/outbox/from-draft/{id}` — turns a draft into a scheduled
    /// outbox message. Body: `{"sendAt": …}`.
    public static func outboxFromDraft(draftId: Int) -> Endpoint<JSONEnvelope<RawBacked<LocalMessage>>> {
        Endpoint(
            name: "outboxFromDraft",
            method: .post,
            encodedPath: "outbox/from-draft/\(draftId)",
            isRetryable: false
        )
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `POST /api/outbox/{id}` — **sends the message now.** The one call that
    /// must never be replayed by anything but the drainer.
    public static func sendOutboxMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "sendOutboxMessage", method: .post, encodedPath: "outbox/\(id)", isRetryable: false)
    }

    /// `DELETE /api/outbox/{id}`.
    public static func deleteOutboxMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteOutboxMessage", method: .delete, encodedPath: "outbox/\(id)", isRetryable: false)
    }
}

// MARK: - Attachment upload

extension Endpoint where Response == LocalAttachment {
    /// `POST /api/attachments` — multipart, field `attachment`; optional field
    /// `accountId` stores the upload under the delegated account's owner.
    /// Answers the bare attachment record, HTTP 201 (verified live). Goes
    /// through ``MailClient/upload(_:multipart:)``.
    public static var uploadAttachment: Endpoint<LocalAttachment> {
        Endpoint(name: "uploadAttachment", method: .post, encodedPath: "attachments", isRetryable: false)
    }
}
