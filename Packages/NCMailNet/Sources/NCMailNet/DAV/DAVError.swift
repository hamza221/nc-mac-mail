// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// What a DAV request can answer with. Deliberately not `MailError`: the Mail
/// API speaks JSON envelopes with app-specific statuses (202, 428); DAV speaks
/// RFC 4918, and conflating them would force every caller through cases that
/// cannot happen on its route.
public enum DAVError: Error, Sendable {
    case unauthorized
    /// 403. sabre explains itself in a `d:error` body; the exception class and
    /// message carry no user data, only server diagnostics.
    case forbidden(exception: String?, message: String?)
    case notFound
    /// 412 — the `If-Match` etag no longer holds. The recovery (refetch, then
    /// reapply the locally edited properties) belongs to the sync engine,
    /// per ADR-0069.
    case preconditionFailed
    /// 405/409 on MKCOL: the collection exists already or the parent is missing.
    case collectionConflict(status: Int, message: String?)
    /// 409 on a PUT: the calendar already holds an object with this UID, at `href` (the
    /// CalDAV `no-uid-conflict` precondition). Nextcloud's scheduling delivers an
    /// invitation into the attendee's default calendar under a name of its own, so an
    /// answer written under ours lands here (ADR-0093).
    case uidConflict(href: String)
    /// A PROPPATCH the server accepted but did not apply for some property.
    case propertyUpdateFailed(status: Int, property: String)
    case server(status: Int, exception: String?, message: String?)
    /// Offline, TLS, timeout — whatever the transport threw.
    case transport(any Error)
    /// A 2xx whose body did not hold what the method requires (a multistatus
    /// that does not parse, a sync answer without a token). The string names
    /// what was missing, never the payload.
    case invalidResponse(String)

    /// Maps a non-2xx response. `data` is the (possibly empty) error body.
    static func status(_ status: Int, data: Data) -> DAVError {
        let parsed = DAVErrorBodyParser.parse(data)
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(exception: parsed.exception, message: parsed.message)
        case 404, 410:
            return .notFound
        case 412:
            return .preconditionFailed
        case 409:
            if let href = parsed.uidConflictHref { return .uidConflict(href: href) }
            return .collectionConflict(status: status, message: parsed.message)
        case 405:
            return .collectionConflict(status: status, message: parsed.message)
        default:
            return .server(status: status, exception: parsed.exception, message: parsed.message)
        }
    }
}
