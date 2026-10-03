// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailCore

/// One call, described: where it goes, how it is spelled, and what comes back.
///
/// The type parameter is phantom. It exists so `client.get(.mailboxes(accountId: 3))`
/// infers its result, which keeps every call site free of a type annotation and
/// keeps every URL in `Endpoints.swift` where the escaping can be reviewed once.
public struct Endpoint<Response>: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case patch = "PATCH"
    }

    /// Which prefix the path hangs off.
    public enum Base: Sendable {
        /// `{server}/index.php/apps/mail/api/`
        case mailAPI
        /// `{server}/` — for OCS routes, which are outside the Mail app.
        case server
    }

    /// A stable, address-free name. It goes in `MailError.decoding` and in the
    /// log, so it must never contain a message id, a mailbox name or an email
    /// address.
    public let name: String
    public let method: Method
    public let base: Base
    /// Already percent-encoded. Build it with ``Endpoint/escape(_:)``.
    public let encodedPath: String
    public let query: [URLQueryItem]
    /// Whether the client may retry this call by itself. True for reads and for
    /// the sync call, which is a read dressed as a write. Never true for a
    /// mutation: replaying one is the drainer's job, because only the drainer
    /// knows what was already applied locally.
    public let isRetryable: Bool

    public init(
        name: String,
        method: Method,
        base: Base = .mailAPI,
        encodedPath: String,
        query: [URLQueryItem] = [],
        isRetryable: Bool
    ) {
        self.name = name
        self.method = method
        self.base = base
        self.encodedPath = encodedPath
        self.query = query
        self.isRetryable = isRetryable
    }

    /// Percent-encode one path segment.
    ///
    /// `CharacterSet.urlPathAllowed` passes `+`, `@`, `:`, `&` and `=` through
    /// untouched. In `/api/avatars/image/{email}` a `+` is part of a real
    /// address and must reach the server as `%2B`, so the allowed set here is
    /// the RFC 3986 unreserved characters and nothing else.
    public static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .ncmUnreserved) ?? segment
    }

    /// The absolute URL for this call against one server.
    func url(relativeTo server: URL) throws -> URL {
        let prefix =
            switch base {
            case .mailAPI: "index.php/apps/mail/api/"
            case .server: ""
            }
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw MailError.transport(URLError(.badURL))
        }
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/" + prefix + encodedPath
        components.percentEncodedQuery = nil
        if !query.isEmpty {
            // Encoded here rather than by `queryItems`, which leaves `+` alone.
            // A `+` in a filter term would otherwise arrive as a space.
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: Self.escape($0.name), value: $0.value.map(Self.escape))
            }
        }
        guard let url = components.url else { throw MailError.transport(URLError(.badURL)) }
        return url
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved: `ALPHA / DIGIT / "-" / "." / "_" / "~"`.
    fileprivate static let ncmUnreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// A response body the client decodes but does not read.
///
/// The mutation endpoints answer with `{"status":"success"}`, with the changed
/// object, with a bare `[]`, or with nothing at all depending on the controller.
/// All of them decode to this, so a caller that only cares whether the call
/// worked does not have to know which. `EmptyBodyRepresentable` covers the
/// "nothing at all" case: a 204 or an empty 200 never reaches `JSONDecoder`.
public struct EmptyResponse: Decodable, Sendable, EmptyBodyRepresentable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
