// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Why `ServerURL.normalize` rejected the input.
public enum ServerURLError: Error, Sendable, Equatable {
    /// Nothing but whitespace.
    case empty
    /// A scheme other than `http` or `https` — `ftp://`, `mailto:`, a bare
    /// word `swift` typo'd as a scheme, and so on.
    case unsupportedScheme
    /// A scheme parsed but no host followed it.
    case missingHost
}

/// Turns what a user types into a server field into the `URL` every other
/// request in this app is built from.
///
/// This is its own tested function, not a step inside `LoginFlow`, because
/// [WS-01's brief](../../../../docs/delivery/briefs/WS-01-auth.md) calls out the
/// server field as "the first thing a user types and the first thing that
/// goes wrong": `cloud.example.com`, `https://cloud.example.com`, a trailing
/// slash, and a path prefix (`https://example.com/nextcloud`) must all reach
/// the same normal form, and anything that is not http(s) must be rejected
/// before it reaches `URLSession`.
public enum ServerURL {
    public static func normalize(_ input: String) throws(ServerURLError) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        // No scheme typed at all: `cloud.example.com`. Assume https rather
        // than guessing from a bare host, which never has one to parse.
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard var components = URLComponents(string: withScheme) else { throw .unsupportedScheme }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw .unsupportedScheme
        }
        components.scheme = scheme

        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        components.host = host.lowercased()

        // Trailing slashes and an empty path both mean "no path prefix"; keep
        // only a real prefix like `/nextcloud`, with no trailing slash, so
        // that `appendingPathComponent` on every later request produces one
        // canonical URL rather than a mix of single- and double-slashed ones.
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path

        // The login and poll steps carry their own query strings; a server
        // field is not the place for one. Drop anything the user pasted.
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw .missingHost }
        return url
    }
}
