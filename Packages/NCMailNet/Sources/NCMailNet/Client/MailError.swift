// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// Everything a Mail request can fail with.
///
/// `decoding` carries the endpoint name because a server-shape change surfaces
/// as a decode failure inside a background actor, and "which endpoint" is the
/// only question worth answering first.
public enum MailError: Error, Sendable {
    /// 401. The app password is gone or was revoked; sign in again.
    case unauthorized
    /// 403. A delegation was withdrawn, or the account no longer exists. The
    /// Mail app also answers 403 for an id the user may not see, which includes
    /// an id that does not exist at all.
    case forbidden
    /// 404 or 410. The thing is gone.
    case notFound
    /// 428, or 400 carrying `MailboxNotCachedException`. Re-send the sync with
    /// `init: true`.
    case mailboxNotCached
    /// 202. `IncompleteSyncException`: the server is still working, retry.
    case syncInProgress
    /// 429 or 503, with whatever `Retry-After` said.
    case rateLimited(retryAfter: Duration?)
    case server(status: Int, message: String?)
    /// Offline, TLS failure, timeout. Not an error the user needs a dialog for.
    case transport(any Error)
    case decoding(any Error, endpoint: String)
}

extension MailError: CustomStringConvertible {
    /// Deliberately free of anything a user wrote. This string reaches the log.
    public var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .notFound: "notFound"
        case .mailboxNotCached: "mailboxNotCached"
        case .syncInProgress: "syncInProgress"
        case .rateLimited(let retryAfter):
            "rateLimited(retryAfter: \(retryAfter.map(String.init(describing:)) ?? "none"))"
        case .server(let status, _): "server(status: \(status))"
        case .transport: "transport"
        case .decoding(_, let endpoint): "decoding(endpoint: \(endpoint))"
        }
    }
}

/// The two failure bodies the Mail app produces.
///
/// `JsonResponse::fail` wraps the message in `data`; a plain controller response
/// puts it at the top level. Both occur on 4xx and 5xx, so both are parsed.
struct MailFailureBody: Decodable {
    let status: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case data
    }

    private enum DataKeys: String, CodingKey {
        case message
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        if let nested = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data),
            let message = try nested.decodeIfPresent(String.self, forKey: .message)
        {
            self.message = message
        } else {
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }
    }

    static func parse(_ data: Data) -> MailFailureBody? {
        try? JSONDecoder().decode(MailFailureBody.self, from: data)
    }

    /// Whether this is the 400 that really means "prime the mailbox first".
    var isMailboxNotCached: Bool {
        guard let message else { return false }
        return message.localizedCaseInsensitiveContains("not cached")
            || message.localizedCaseInsensitiveContains("MailboxNotCached")
    }
}
