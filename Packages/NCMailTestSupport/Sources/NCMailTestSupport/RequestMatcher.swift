// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Which requests a `FakeTransport` stub applies to.
///
/// Matches on the `URLRequest` itself, not on `NCMailNet`'s `Endpoint` — the transport only
/// ever sees a built request, and matching at that layer is what lets `FakeTransport` stay
/// ignorant of any particular endpoint's shape.
public struct RequestMatcher: Sendable {
    private let predicate: @Sendable (URLRequest) -> Bool
    /// For the message a test sees when nothing matched. Not load-bearing otherwise.
    public let description: String

    public init(_ description: String, _ predicate: @escaping @Sendable (URLRequest) -> Bool) {
        self.description = description
        self.predicate = predicate
    }

    public func matches(_ request: URLRequest) -> Bool { predicate(request) }

    /// Every request. The common case in a test that only talks to one endpoint.
    public static let any = RequestMatcher("any request") { _ in true }

    public static func method(_ method: String) -> RequestMatcher {
        RequestMatcher("method \(method)") { $0.httpMethod?.caseInsensitiveCompare(method) == .orderedSame }
    }

    /// The exact path, e.g. `/index.php/apps/mail/api/mailboxes/5/sync`.
    public static func path(_ path: String) -> RequestMatcher {
        RequestMatcher("path \(path)") { $0.url?.path == path }
    }

    /// A path ending in `suffix` — `.pathSuffix("/sync")` matches every mailbox's sync route
    /// without naming the mailbox id.
    public static func pathSuffix(_ suffix: String) -> RequestMatcher {
        RequestMatcher("path ending \(suffix)") { ($0.url?.path).map { $0.hasSuffix(suffix) } ?? false }
    }

    public static func pathContains(_ substring: String) -> RequestMatcher {
        RequestMatcher("path containing \(substring)") { ($0.url?.path).map { $0.contains(substring) } ?? false }
    }

    // MARK: - DAV

    // WebDAV speaks in methods HTTP never standardised; spelling them out keeps DAV tests
    // from scattering magic strings. `method(_:)` already compares case-insensitively.

    public static let propfind = method("PROPFIND")
    public static let report = method("REPORT")
    public static let mkcol = method("MKCOL")
    public static let proppatch = method("PROPPATCH")

    /// The DAV `Depth` header — `.propfind && .depth("1")` is "list the collection" as
    /// opposed to "describe the resource".
    public static func depth(_ value: String) -> RequestMatcher {
        header("Depth", value)
    }

    // MARK: - Headers

    /// An exact header value, compared case-insensitively on the name (HTTP headers are)
    /// and exactly on the value.
    public static func header(_ name: String, _ value: String) -> RequestMatcher {
        RequestMatcher("header \(name): \(value)") { $0.value(forHTTPHeaderField: name) == value }
    }

    /// A header whose value contains `substring` — `Content-Type` carries parameters
    /// (`charset`, `boundary`) that an exact match would have to spell out.
    public static func header(_ name: String, contains substring: String) -> RequestMatcher {
        RequestMatcher("header \(name) containing \(substring)") {
            $0.value(forHTTPHeaderField: name)?.contains(substring) ?? false
        }
    }

    // MARK: - Bodies

    /// The request body contains `substring` when read as UTF-8. The way to pin a stub to
    /// one DAV report — `.report && .bodyContains("sync-collection")` — without asserting
    /// the exact XML serialisation, which the client is free to change.
    ///
    /// Reads `httpBody` only. `MailTransport` implementations build requests with bodies as
    /// `Data`; a streamed body (`httpBodyStream`) never matches, deliberately, because
    /// consuming the stream here would leave nothing for the code under test.
    public static func bodyContains(_ substring: String) -> RequestMatcher {
        RequestMatcher("body containing \(substring)") { request in
            guard let body = request.httpBody else { return false }
            return String(decoding: body, as: UTF8.self).contains(substring)
        }
    }

    // MARK: - Multipart

    /// Any multipart body, regardless of subtype — `multipart/form-data` for the attachment
    /// upload, but written loosely so an S/MIME `multipart/signed` test can reuse it.
    public static let multipart = RequestMatcher("multipart body") { request in
        request.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("multipart/") ?? false
    }

    /// A multipart body carrying a form field named `name` — `POST /api/attachments` puts
    /// the file in `attachment`, S/MIME import in `certificate` and `privateKey`. Matches
    /// the `Content-Disposition` part header rather than parsing the full MIME tree: the
    /// field name in quotes after `name=` is unambiguous within a body the test itself
    /// built. Same `httpBody`-only rule as `bodyContains`.
    public static func multipartField(named name: String) -> RequestMatcher {
        multipart
            && RequestMatcher("multipart field \(name)") { request in
                guard let body = request.httpBody else { return false }
                return String(decoding: body, as: UTF8.self).contains("name=\"\(name)\"")
            }
    }
}

/// Both must match. `.method("POST") && .pathSuffix("/sync")` is the usual way to pin a
/// stub to one endpoint without spelling out its full path.
public func && (lhs: RequestMatcher, rhs: RequestMatcher) -> RequestMatcher {
    RequestMatcher("\(lhs.description) and \(rhs.description)") { lhs.matches($0) && rhs.matches($0) }
}
