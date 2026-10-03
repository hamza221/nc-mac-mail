// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The `ncmail://asset/{base64url(absolute URL)}` spelling from
/// [ADR-0010](../../docs/decisions/0010-webview-scheme-handler.md), in one place.
///
/// Base64url rather than percent-encoding, because the payload is itself a URL with its own
/// query string: percent-encoding a `?` once produces a URL that `URLComponents` takes apart
/// again in the wrong place, and every layer between here and `WKURLSchemeHandler` gets a
/// vote on re-normalising it. Base64url survives all of them — it is `[A-Za-z0-9_-]` and
/// nothing else, so there is nothing left for anything to normalise.
nonisolated enum MailAssetURL {
    /// Registered on the configuration, and the only scheme the content rule list lets
    /// through.
    static let scheme = "ncmail"

    /// The one host we answer for. A second one would be a second allowlist to keep right.
    static let host = "asset"

    /// The `ncmail:` URL that stands in for `url` inside a rendered message.
    ///
    /// - Returns: nil only when the encoded form will not parse as a URL, which cannot happen
    ///   for base64url output but is not worth a force unwrap to prove.
    static func encode(_ url: URL) -> URL? {
        URL(string: "\(scheme)://\(host)/\(base64url(Data(url.absoluteString.utf8)))")
    }

    /// The absolute URL a `ncmail:` URL stands for, or nil when it is not one of ours.
    ///
    /// Everything about the shape is checked here rather than by the caller: scheme, host,
    /// exactly one path component, decodable payload, and an absolute URL at the end of it.
    static func decode(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return nil }
        let payload = url.path().trimmingPrefix("/")
        guard !payload.isEmpty, !payload.contains("/") else { return nil }
        guard let data = decodeBase64url(String(payload)) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let decoded = URL(string: text), decoded.scheme != nil, decoded.host() != nil else { return nil }
        return decoded
    }

    // MARK: - Base64url

    /// RFC 4648 §5: the URL-safe alphabet, padding removed.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64url(_ text: String) -> Data? {
        var standard =
            text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Four characters per three bytes, so the remainder is 0, 2 or 3 characters; a
        // remainder of 1 is not base64 at all and `Data(base64Encoded:)` rejects it.
        let remainder = standard.count % 4
        if remainder > 0 { standard.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: standard)
    }
}
