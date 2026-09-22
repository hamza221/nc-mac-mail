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
}

/// Both must match. `.method("POST") && .pathSuffix("/sync")` is the usual way to pin a
/// stub to one endpoint without spelling out its full path.
public func && (lhs: RequestMatcher, rhs: RequestMatcher) -> RequestMatcher {
    RequestMatcher("\(lhs.description) and \(rhs.description)") { lhs.matches($0) && rhs.matches($0) }
}
