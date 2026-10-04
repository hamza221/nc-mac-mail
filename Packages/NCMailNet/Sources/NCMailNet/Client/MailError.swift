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
    /// 400 carrying `CouldNotConnectException`'s fail envelope from account create/update
    /// (`{"status":"fail","data":{"error":…,"service":…,"host":…,"port":…}}`). `service`
    /// is `IMAP` or `SMTP`; `reason` is `AUTHENTICATION_WRONG_PASSWORD`,
    /// `AUTHENTICATION_DENIED`, `AUTHENTICATION`, `CONNECTION_ERROR` or `OTHER` — the
    /// account form's error strings key off both.
    case connectFailed(service: String, reason: String)
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
        case .connectFailed(let service, let reason): "connectFailed(\(service), \(reason))"
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
    /// `data.error` and `data.service` of a `CouldNotConnectException` fail envelope.
    let connectReason: String?
    let connectService: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case message
        case data
    }

    private enum DataKeys: String, CodingKey {
        case message
        case error
        case service
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        let nested = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        if let nested, let message = try? nested.decodeIfPresent(String.self, forKey: .message) {
            self.message = message
        } else {
            message = try container.decodeIfPresent(String.self, forKey: .message)
        }
        connectReason = try? nested?.decodeIfPresent(String.self, forKey: .error)
        connectService = try? nested?.decodeIfPresent(String.self, forKey: .service)
    }

    static func parse(_ data: Data) -> MailFailureBody? {
        try? JSONDecoder().decode(MailFailureBody.self, from: data)
    }

    /// The fail envelope account create/update answer when IMAP or SMTP refused.
    var connectFailure: MailError? {
        guard let connectReason, let connectService else { return nil }
        return .connectFailed(service: connectService, reason: connectReason)
    }

    /// Whether this is the 400 that really means "prime the mailbox first".
    var isMailboxNotCached: Bool {
        guard let message else { return false }
        return message.localizedCaseInsensitiveContains("not cached")
            || message.localizedCaseInsensitiveContains("MailboxNotCached")
    }
}
