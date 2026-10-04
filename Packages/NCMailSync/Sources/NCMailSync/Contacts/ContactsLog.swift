// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import NCMailNet
internal import OSLog

/// Loggers for the contacts and calendar-list mirrors.
///
/// The vocabulary: login ids, address book and contact row ids, counts, HTTP statuses, and
/// vCard property *names* (`EMAIL`, `TEL`) — schema, never values. An href carries the login
/// name and a card's file name is often the person's name, so neither is interpolated, at any
/// level.
enum ContactsLog {
    static let contacts = Logger(subsystem: "com.nextcloud.mail.macos", category: "contacts")
    static let calendars = Logger(subsystem: "com.nextcloud.mail.macos", category: "calendars")
}

/// An error's shape for a log line: the case and status, never a server message, which can
/// quote a path and therefore the login name.
func describeDAV(_ error: any Error) -> String {
    guard let dav = error as? DAVError else { return String(describing: type(of: error)) }
    switch dav {
    case .unauthorized: return "unauthorized"
    case .forbidden(let exception, _): return "forbidden(\(exception ?? "-"))"
    case .notFound: return "notFound"
    case .preconditionFailed: return "preconditionFailed"
    case .collectionConflict(let status, _): return "collectionConflict(\(status))"
    case .propertyUpdateFailed(let status, _): return "propertyUpdateFailed(\(status))"
    case .server(let status, let exception, _): return "server(\(status), \(exception ?? "-"))"
    case .transport: return "transport"
    case .invalidResponse(let what): return "invalidResponse(\(what))"
    }
}
