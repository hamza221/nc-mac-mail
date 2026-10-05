// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
public import NCMailCore

// Mailbox management. The v1 surface (list, sync) stays in `Endpoints.swift`.

extension Endpoint where Response == RawBacked<Mailbox> {
    /// `POST /api/mailboxes`. Body: `{"accountId": …, "name": …}` — use the
    /// account's delimiter in `name` for a subfolder. Answers the mailbox JSON.
    public static var createMailbox: Endpoint<RawBacked<Mailbox>> {
        Endpoint(name: "createMailbox", method: .post, encodedPath: "mailboxes", isRetryable: false)
    }

    /// `PATCH /api/mailboxes/{id}`. Optional body keys: `name` (rename or
    /// move), `subscribed`, `syncInBackground`. Answers the updated mailbox
    /// JSON (verified live), so a rename lands without a mailbox-list refetch.
    public static func patchMailbox(id: Int) -> Endpoint<RawBacked<Mailbox>> {
        Endpoint(name: "patchMailbox", method: .patch, encodedPath: "mailboxes/\(id)", isRetryable: false)
    }
}

extension Endpoint where Response == EmptyResponse {
    /// `DELETE /api/mailboxes/{id}` — the folder and everything in it.
    public static func deleteMailbox(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteMailbox", method: .delete, encodedPath: "mailboxes/\(id)", isRetryable: false)
    }

    /// `POST /api/mailboxes/{id}/clear` — deletes every message in the folder.
    public static func clearMailbox(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "clearMailbox", method: .post, encodedPath: "mailboxes/\(id)/clear", isRetryable: false)
    }

    /// `POST /api/mailboxes/{id}/read` — marks every message read.
    public static func markMailboxRead(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "markMailboxRead", method: .post, encodedPath: "mailboxes/\(id)/read", isRetryable: false)
    }

    /// `POST /api/mailboxes/{id}/repair` — rebuilds the server's local state
    /// for the folder. Rate limited at 10 per 600 s, and not retryable: it is
    /// a repair the user triggers, not a read.
    public static func repairMailbox(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "repairMailbox", method: .post, encodedPath: "mailboxes/\(id)/repair", isRetryable: false)
    }
}

extension Endpoint where Response == MailboxStats {
    /// `GET /api/mailboxes/{id}/stats` — `{"total": …, "unread": …}`.
    public static func mailboxStats(id: Int) -> Endpoint<MailboxStats> {
        Endpoint(name: "mailboxStats", method: .get, encodedPath: "mailboxes/\(id)/stats", isRetryable: true)
    }
}
