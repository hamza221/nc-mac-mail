// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Every way the system can point the app at something, as one value: a URL the app was
/// asked to open (Info.plist registers `mailto:` and `ncmail:`), a Spotlight result, a
/// widget tap, the Share extension's hand-off and the Services menu.
///
/// The `ncmail:` spellings:
///
/// - `ncmail://open/<Message-ID>` — WS-30's "Copy direct link", the native spelling of the
///   web's `/apps/mail/open/<Message-ID>`; the id percent-encoded, angle brackets included.
/// - `ncmail://message/<local id>` — a widget row.
/// - `ncmail://shared/<inbox item id>` — the Share extension, after writing the item.
///
/// `ncmail://asset/…` is the message WebView's own scheme (ADR-0010) and is not a link the
/// app opens; it parses to nil like every other unknown host.
nonisolated enum SystemLink: Equatable, Sendable {
    /// A `mailto:` URL, for `ComposeRequest.new(accountId: nil, mailto:)`.
    case compose(mailto: URL)
    /// The `Message-ID` header, decoded, brackets kept.
    case openMessageId(String)
    case message(Int64)
    case contact(Int64)
    case shared(inboxItemId: String)

    static let scheme = "ncmail"

    init?(url: URL) {
        switch url.scheme?.lowercased() {
        case "mailto":
            self = .compose(mailto: url)
        case Self.scheme:
            guard let link = Self.parseNCMail(url) else { return nil }
            self = link
        default:
            return nil
        }
    }

    /// The URL for the cases that have one; Spotlight's are identifiers, not URLs.
    var url: URL? {
        switch self {
        case .compose(let mailto): return mailto
        case .openMessageId(let header):
            var unreserved = CharacterSet.alphanumerics
            unreserved.insert(charactersIn: "-._~")
            return header.addingPercentEncoding(withAllowedCharacters: unreserved)
                .flatMap { URL(string: "ncmail://open/\($0)") }
        case .message(let id): return URL(string: "ncmail://message/\(id)")
        case .contact(let id): return URL(string: "ncmail://contact/\(id)")
        case .shared(let itemId): return URL(string: "ncmail://shared/\(itemId)")
        }
    }

    /// A Services selection as a new message: the text goes in the body of a bare
    /// `mailto:`, which is the one shape the composer already reads every field from.
    static func compose(body: String) -> SystemLink? {
        // `&`, `=` and `+` must be escaped, or a body would split into fields.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "mailto:?body=\(encoded)")
        else { return nil }
        return .compose(mailto: url)
    }

    /// The host names the action; everything after it is one opaque, percent-encoded
    /// argument. The raw path is used so an encoded `/` inside a Message-ID stays inside it.
    private static func parseNCMail(_ url: URL) -> SystemLink? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        var raw = url.path(percentEncoded: true)
        guard raw.hasPrefix("/") else { return nil }
        raw.removeFirst()
        if raw.hasSuffix("/") { raw.removeLast() }
        guard !raw.isEmpty, !raw.contains("/"), let argument = raw.removingPercentEncoding,
            !argument.isEmpty
        else { return nil }
        switch host {
        case "open":
            return .openMessageId(argument)
        case "message":
            return Int64(argument).map(SystemLink.message)
        case "contact":
            return Int64(argument).map(SystemLink.contact)
        case "shared":
            guard argument != ".", argument != "..", !argument.contains("/") else { return nil }
            return .shared(inboxItemId: argument)
        default:
            return nil
        }
    }
}
