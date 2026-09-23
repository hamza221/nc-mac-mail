// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The two shapes of URL a message body is allowed to load, and nothing else.
///
/// This is the allowlist [ADR-0010](../../docs/decisions/0010-webview-scheme-handler.md)
/// describes, written once and used twice: the rewriter asks it what a URL in the stored
/// HTML may become, and the scheme handler asks it again about the URL the WebView actually
/// requested. Two checks of one rule, so a rewriting bug cannot widen what the handler will
/// serve.
nonisolated enum MailAssetKind: Equatable, Sendable {
    /// `…/apps/mail/api/messages/{id}/attachment/{aid}` — an inline image of *this* message.
    case inlineAttachment(attachmentId: String)
    /// `…/apps/mail/proxy?src=…&id=…&hmac=…` — a remote image, fetched by the server so the
    /// reader's address never reaches the sender.
    case proxiedRemoteImage
}

/// Why a URL was refused. Cases rather than a bool because the handler logs which rule
/// fired, and "off server" and "blocked" are different stories.
nonisolated enum MailAssetRefusal: Equatable, Sendable {
    case notAnAssetURL
    case offServer
    case notAnAllowedPath
    /// An attachment URL naming a different message than the one on screen.
    case otherMessage
    case remoteImagesBlocked
    case unknownAttachment
}

nonisolated enum MailAssetPolicy {
    /// Classifies an absolute URL against the signed-in server.
    ///
    /// - Returns: what the URL is, or nil when it is not one of the two allowed shapes.
    static func classify(_ url: URL, server: URL, messageRemoteId: Int64) -> MailAssetKind? {
        guard isOnServer(url, server: server) else { return nil }
        guard var path = relativePath(of: url, server: server) else { return nil }
        // A Nextcloud can be reached with or without the front controller in the path, and
        // both spellings appear in one message when the sanitiser rewrites only some of them.
        if path.hasPrefix("index.php/") { path.removeFirst("index.php/".count) }
        guard path.hasPrefix("apps/mail/") else { return nil }
        let rest = String(path.dropFirst("apps/mail/".count))

        if rest == "proxy" { return .proxiedRemoteImage }

        let components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 5,
            components[0] == "api",
            components[1] == "messages",
            components[3] == "attachment",
            let remoteId = Int64(components[2]),
            remoteId == messageRemoteId,
            !components[4].isEmpty
        else { return nil }
        return .inlineAttachment(attachmentId: components[4])
    }

    /// Same scheme, same host, same effective port. A message that moves its images to
    /// `cloud.example.com.evil.test` fails here and not later.
    static func isOnServer(_ url: URL, server: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let serverScheme = server.scheme?.lowercased(),
            scheme == serverScheme,
            let host = url.host()?.lowercased(), let serverHost = server.host()?.lowercased(),
            host == serverHost,
            port(of: url) == port(of: server)
        else { return false }
        return true
    }

    /// The part of `url`'s path that comes after the server's own base path, with no leading
    /// slash. Nil when the URL sits outside the installation's directory.
    static func relativePath(of url: URL, server: URL) -> String? {
        var base = server.path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        var path = url.path(percentEncoded: false)
        if !base.isEmpty {
            guard path.hasPrefix(base) else { return nil }
            path.removeFirst(base.count)
        }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    private static func port(of url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }
}
