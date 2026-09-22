// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore

// Every URL the app builds is in this file. Escaping is reviewed once, here,
// rather than at twenty call sites -- and the one that matters is the avatar
// route, where a `+` in an address has to survive as `%2B`.
//
// `isRetryable` is set per endpoint rather than derived from the verb: the sync
// call is a POST that reads, and a mutation must never be replayed by the
// client whatever its verb.

// MARK: - Accounts

extension Endpoint where Response == [RawBacked<Account>] {
    public static var accounts: Endpoint<[RawBacked<Account>]> {
        Endpoint(name: "accounts", method: .get, encodedPath: "accounts", isRetryable: true)
    }
}

extension Endpoint where Response == RawBacked<Account> {
    public static func account(id: Int) -> Endpoint<RawBacked<Account>> {
        Endpoint(name: "account", method: .get, encodedPath: "accounts/\(id)", isRetryable: true)
    }
}

// MARK: - Mailboxes

extension Endpoint where Response == MailboxList {
    public static func mailboxes(accountId: Int, forceSync: Bool = false) -> Endpoint<MailboxList> {
        var query = [URLQueryItem(name: "accountId", value: String(accountId))]
        if forceSync { query.append(URLQueryItem(name: "forceSync", value: "true")) }
        return Endpoint(name: "mailboxes", method: .get, encodedPath: "mailboxes", query: query, isRetryable: true)
    }
}

extension Endpoint where Response == MailboxStats {
    public static func mailboxStats(mailboxId: Int) -> Endpoint<MailboxStats> {
        Endpoint(
            name: "mailboxStats",
            method: .get,
            encodedPath: "mailboxes/\(mailboxId)/stats",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == SyncResponse {
    /// A POST that reads, so it is the one non-GET the client may retry.
    public static func sync(mailboxId: Int) -> Endpoint<SyncResponse> {
        Endpoint(
            name: "sync",
            method: .post,
            encodedPath: "mailboxes/\(mailboxId)/sync",
            isRetryable: true
        )
    }
}

// MARK: - Messages

extension Endpoint where Response == [RawBacked<Envelope>] {
    /// The enumeration call. `view` is `singleton` because `threaded` returns
    /// one message per thread and silently drops every reply (ADR-0014).
    ///
    /// - Parameter cursor: the `dateInt` of the oldest envelope seen so far.
    /// - Parameter limit: clamped server-side to 1...100.
    public static func messages(
        mailboxId: Int,
        cursor: Int? = nil,
        limit: Int = 100,
        view: String = "singleton",
        filter: String? = nil
    ) -> Endpoint<[RawBacked<Envelope>]> {
        var query = [
            URLQueryItem(name: "mailboxId", value: String(mailboxId)),
            URLQueryItem(name: "view", value: view),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        return Endpoint(name: "messages", method: .get, encodedPath: "messages", query: query, isRetryable: true)
    }

    public static func messageThread(messageId: Int) -> Endpoint<[RawBacked<Envelope>]> {
        Endpoint(
            name: "messageThread",
            method: .get,
            encodedPath: "messages/\(messageId)/thread",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == RawBacked<Envelope> {
    public static func message(id: Int) -> Endpoint<RawBacked<Envelope>> {
        Endpoint(name: "message", method: .get, encodedPath: "messages/\(id)", isRetryable: true)
    }
}

extension Endpoint where Response == RawBacked<MessageBody> {
    public static func messageBody(id: Int) -> Endpoint<RawBacked<MessageBody>> {
        Endpoint(name: "messageBody", method: .get, encodedPath: "messages/\(id)/body", isRetryable: true)
    }
}

// MARK: - Bytes

extension Endpoint where Response == Data {
    /// `plain=true` returns the sanitised fragment on its own. Without it the
    /// server wraps it in a document with an iframe-resizer script and a CSP
    /// nonce, and we build our own shell.
    public static func messageHTML(id: Int) -> Endpoint<Data> {
        Endpoint(
            name: "messageHtml",
            method: .get,
            encodedPath: "messages/\(id)/html",
            query: [URLQueryItem(name: "plain", value: "true")],
            isRetryable: true
        )
    }

    /// `attachmentId` is a MIME part path such as `2.1`, so it is escaped as a
    /// path segment rather than interpolated.
    public static func attachment(messageId: Int, attachmentId: String) -> Endpoint<Data> {
        Endpoint(
            name: "attachment",
            method: .get,
            encodedPath: "messages/\(messageId)/attachment/\(escape(attachmentId))",
            isRetryable: true
        )
    }

    /// A 404 here is normal and means "draw initials".
    public static func avatar(email: String) -> Endpoint<Data> {
        Endpoint(
            name: "avatar",
            method: .get,
            encodedPath: "avatars/image/\(escape(email))",
            isRetryable: true
        )
    }
}

// MARK: - Mutations

// None of these is retryable. Replaying a move that already applied is how a
// message ends up in the wrong folder; the drainer owns that decision because
// only it knows what was written locally.

extension Endpoint where Response == EmptyResponse {
    public static func setFlags(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "setFlags",
            method: .put,
            encodedPath: "messages/\(messageId)/flags",
            isRetryable: false
        )
    }

    public static func moveMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "moveMessage", method: .post, encodedPath: "messages/\(id)/move", isRetryable: false)
    }

    /// Moves to trash, or erases when the message is already in trash.
    public static func deleteMessage(id: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteMessage", method: .delete, encodedPath: "messages/\(id)", isRetryable: false)
    }

    /// `id` is any message in the thread; the server resolves the root.
    public static func moveThread(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "moveThread", method: .post, encodedPath: "thread/\(messageId)", isRetryable: false)
    }

    public static func deleteThread(messageId: Int) -> Endpoint<EmptyResponse> {
        Endpoint(name: "deleteThread", method: .delete, encodedPath: "thread/\(messageId)", isRetryable: false)
    }

    /// - Parameter type: `individual` or `domain`.
    public static func trustSender(email: String, type: String = "individual") -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "trustSender",
            method: .put,
            encodedPath: "trustedsenders/\(escape(email))",
            query: [URLQueryItem(name: "type", value: type)],
            isRetryable: false
        )
    }

    public static func untrustSender(email: String, type: String = "individual") -> Endpoint<EmptyResponse> {
        Endpoint(
            name: "untrustSender",
            method: .delete,
            encodedPath: "trustedsenders/\(escape(email))",
            query: [URLQueryItem(name: "type", value: type)],
            isRetryable: false
        )
    }
}

// MARK: - Settings and theming

extension Endpoint where Response == TrustedSendersResponse {
    public static var trustedSenders: Endpoint<TrustedSendersResponse> {
        Endpoint(name: "trustedSenders", method: .get, encodedPath: "trustedsenders", isRetryable: true)
    }
}

extension Endpoint where Response == Preference {
    /// Keys worth reading: `sort-order`, `layout-message-view`,
    /// `external-avatars`, `auto-mark-as-read`. v1 reads, never writes.
    public static func preference(key: String) -> Endpoint<Preference> {
        Endpoint(
            name: "preference",
            method: .get,
            encodedPath: "preferences/\(escape(key))",
            isRetryable: true
        )
    }
}

extension Endpoint where Response == OCSResponse<Capabilities> {
    /// Outside the Mail app's routes, so it takes the OCS prefix rather than
    /// the mail API one.
    public static var capabilities: Endpoint<OCSResponse<Capabilities>> {
        Endpoint(
            name: "capabilities",
            method: .get,
            base: .server,
            encodedPath: "ocs/v2.php/cloud/capabilities",
            isRetryable: true
        )
    }
}
