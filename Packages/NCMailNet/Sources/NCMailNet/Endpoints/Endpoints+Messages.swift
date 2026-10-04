// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore

// The v2 message surface: raw source, exports, verification results, tags,
// snooze, receipts, Files integration and the LLM routes — plus the thread
// variants. The v1 surface (list, body, flags, move, delete) stays in
// `Endpoints.swift`.

// MARK: - Message detail

extension Endpoint where Response == MessageSource {
    /// `GET /api/messages/{id}/source` — `{"source": "<RFC 822>"}`.
    public static func messageSource(id: Int) -> Endpoint<MessageSource> {
        Endpoint(name: "messageSource", method: .get, encodedPath: "messages/\(id)/source", isRetryable: true)
    }
}

extension Endpoint where Response == [AnyJSON] {
    /// `GET /api/messages/{id}/itineraries` — the KItinerary extraction, a bare
    /// array (verified live, empty). Elements are KItinerary's JSON-LD, which
    /// the client passes to the calendar surface whole rather than remodelling.
    public static func itineraries(messageId: Int) -> Endpoint<[AnyJSON]> {
        Endpoint(name: "itineraries", method: .get, encodedPath: "messages/\(messageId)/itineraries", isRetryable: true)
    }
}

extension Endpoint where Response == DkimResult {
    /// `GET /api/messages/{id}/dkim` — `{"valid": bool}`, bare (verified live).
    public static func dkim(messageId: Int) -> Endpoint<DkimResult> {
        Endpoint(name: "dkim", method: .get, encodedPath: "messages/\(messageId)/dkim", isRetryable: true)
    }
}

// MARK: - Bytes

extension Endpoint where Response == Data {
    /// `GET /api/messages/{id}/export` — the message as an `.eml` download.
    public static func exportMessage(id: Int) -> Endpoint<Data> {
        Endpoint(name: "exportMessage", method: .get, encodedPath: "messages/\(id)/export", isRetryable: true)
    }

    /// `GET /api/messages/{id}/attachments` — every attachment as one zip.
    public static func attachmentsZip(messageId: Int) -> Endpoint<Data> {
        Endpoint(
            name: "attachmentsZip",
            method: .get,
            encodedPath: "messages/\(messageId)/attachments",
            isRetryable: true
        )
    }
}

// MARK: - Tags on a message

extension Endpoint where Response == Tag {
    /// `PUT /api/messages/{id}/tags/{imapLabel}`. The label is an IMAP keyword
    /// such as `$label1`, escaped as a path segment. Both tag routes answer
    /// the tag itself, bare (verified live).
    public static func addMessageTag(messageId: Int, imapLabel: String) -> Endpoint<Tag> {
        Endpoint(
            name: "addMessageTag",
            method: .put,
            encodedPath: "messages/\(messageId)/tags/\(escape(imapLabel))",
            isRetryable: false
        )
    }

    /// `DELETE /api/messages/{id}/tags/{imapLabel}`.
    public static func removeMessageTag(messageId: Int, imapLabel: String) -> Endpoint<Tag> {
        Endpoint(
            name: "removeMessageTag",
            method: .delete,
            encodedPath: "messages/\(messageId)/tags/\(escape(imapLabel))",
            isRetryable: false
        )
    }
}

// MARK: - Snooze and receipts

extension Endpoint where Response == EmptyResponse {
    /// `POST /api/messages/{id}/snooze`. Body: `unixTimestamp`, `destMailboxId`.
    public static func snoozeMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "snoozeMessage", method: .post, encodedPath: "messages/\(id)/snooze", isRetryable: false)
    }

    /// `POST /api/messages/{id}/unsnooze`.
    public static func unsnoozeMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "unsnoozeMessage", method: .post, encodedPath: "messages/\(id)/unsnooze", isRetryable: false)
    }

    /// `POST /api/messages/{id}/mdn` — sends the read receipt the message
    /// asked for. A message without `Disposition-Notification-To` answers
    /// **HTTP 500** with the error envelope (observed live), so the caller
    /// offers the action only when the body says a receipt was requested.
    public static func sendMDN(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "sendMdn", method: .post, encodedPath: "messages/\(messageId)/mdn", isRetryable: false)
    }

    // MARK: - Files integration

    /// `POST /api/messages/{id}/attachment/{attachmentId}` — saves one
    /// attachment into Files. Body: `{"targetPath": …}`. The id is a MIME part
    /// path (`2.1`), escaped like the download route's.
    public static func saveAttachmentToFiles(messageId: Int, attachmentId: String) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "saveAttachmentToFiles",
            method: .post,
            encodedPath: "messages/\(messageId)/attachment/\(escape(attachmentId))",
            isRetryable: false
        )
    }

    /// `POST /api/messages/{id}/file` — saves the whole message into Files as
    /// `.eml`. Body: `{"targetPath": …}`.
    public static func saveMessageToFiles(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "saveMessageToFiles",
            method: .post,
            encodedPath: "messages/\(messageId)/file",
            isRetryable: false
        )
    }

    // MARK: - Mailing list

    /// `POST /api/list/unsubscribe/{id}` — acts on the message's
    /// `List-Unsubscribe` header server-side. A message without a one-click
    /// header answers **HTTP 403** `{"status":"fail","data":null}` (observed
    /// live), which maps to `MailError.forbidden`.
    public static func unsubscribe(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "unsubscribe", method: .post, encodedPath: "list/unsubscribe/\(messageId)", isRetryable: false)
    }
}

// MARK: - LLM routes

extension Endpoint where Response == SmartReplyResponse {
    /// `GET /api/messages/{messageId}/smartreply` — suggested replies as a bare
    /// JSON array of strings (verified live). **204 with an empty body** when the
    /// server has no LLM provider; `EmptyBodyRepresentable` turns that into none.
    public static func smartReply(messageId: Int) -> Endpoint<SmartReplyResponse> {
        Endpoint(name: "smartReply", method: .get, encodedPath: "messages/\(messageId)/smartreply", isRetryable: true)
    }
}

// MARK: - Threads

// `{id}` on every thread route is the id of any message in the thread; the
// server resolves the root. Move and delete live in `Endpoints.swift`.

extension Endpoint where Response == EmptyResponse {
    /// `POST /api/thread/{id}/snooze`. Body: `unixTimestamp`, `destMailboxId`.
    public static func snoozeThread(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "snoozeThread", method: .post, encodedPath: "thread/\(messageId)/snooze", isRetryable: false)
    }

    /// `POST /api/thread/{id}/unsnooze`.
    public static func unsnoozeThread(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "unsnoozeThread", method: .post, encodedPath: "thread/\(messageId)/unsnooze", isRetryable: false)
    }
}

extension Endpoint where Response == ThreadSummaryResponse {
    /// `GET /api/thread/{id}/summary` — an LLM summary; 204 when no provider
    /// (verified live).
    public static func threadSummary(messageId: Int) -> Endpoint<ThreadSummaryResponse> {
        Endpoint(name: "threadSummary", method: .get, encodedPath: "thread/\(messageId)/summary", isRetryable: true)
    }
}

extension Endpoint where Response == JSONEnvelope<EventData?> {
    /// `GET /api/thread/{id}/eventdata` — a suggested calendar event title and
    /// agenda. `{"data": null}` when there is nothing to suggest (verified live).
    public static func threadEventData(messageId: Int) -> Endpoint<JSONEnvelope<EventData?>> {
        Endpoint(
            name: "threadEventData",
            method: .get,
            encodedPath: "thread/\(messageId)/eventdata",
            isRetryable: true
        )
    }
}
