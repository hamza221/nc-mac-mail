// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// `mailto:` URLs (RFC 6068) into composer fields, for `ComposeRequest.new(mailto:)` (§6.2).
///
/// Every field the web client's `/mailto?to&cc&bcc&subject&body` route reads, named
/// addresses kept, and an HTML body recognised so it opens as rich text.
nonisolated struct MailtoFields: Equatable, Sendable {
    var to: [ComposerAddress] = []
    var cc: [ComposerAddress] = []
    var bcc: [ComposerAddress] = []
    var subject: String?
    var body: String?

    /// The body carries markup, so the composer imports it as rich text.
    var bodyIsHTML: Bool {
        guard let body else { return false }
        return body.range(
            of: #"<(p|div|br|b|i|u|a|span|strong|em|ul|ol|li|h[1-6]|blockquote|table)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    init(
        to: [ComposerAddress] = [], cc: [ComposerAddress] = [], bcc: [ComposerAddress] = [],
        subject: String? = nil, body: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Nil when the URL is not a `mailto:` URL at all.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        self.init(string: url.absoluteString)
    }

    /// Parses the string form, which is what survives a URL that `URL` itself would mangle
    /// (spaces, unescaped `&` in names).
    init?(string: String) {
        guard string.lowercased().hasPrefix("mailto:") else { return nil }
        let rest = string.dropFirst("mailto:".count)
        let (path, query) = Self.split(rest)
        to = AddressParser.parseList(Self.decode(path))
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].lowercased()
            let value = parts.count > 1 ? Self.decode(parts[1]) : ""
            switch name {
            case "to": to += AddressParser.parseList(value)
            case "cc": cc += AddressParser.parseList(value)
            case "bcc": bcc += AddressParser.parseList(value)
            case "subject": subject = value
            case "body": body = value
            default: continue
            }
        }
        to = ReplyRecipients.dedupe(to)
        cc = ReplyRecipients.dedupe(cc, excluding: to)
        bcc = ReplyRecipients.dedupe(bcc, excluding: to + cc)
    }

    private static func split(_ rest: Substring) -> (Substring, Substring) {
        guard let question = rest.firstIndex(of: "?") else { return (rest, "") }
        return (rest[..<question], rest[rest.index(after: question)...])
    }

    /// Percent-decoding; `+` stays a plus (RFC 6068 is not form encoding).
    private static func decode<S: StringProtocol>(_ text: S) -> String {
        String(text).removingPercentEncoding ?? String(text)
    }
}
