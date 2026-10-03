// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The schemes a click in a message may hand to the system.
///
/// Checked twice, deliberately: the rewriter drops an `href` that is not one of these, and
/// the navigation delegate checks again before anything reaches `openURL`. The second check
/// is what stands between a `file:` or `x-something:` URL and whatever is registered to
/// handle it, if the first one is ever wrong.
nonisolated enum MailLinkScheme {
    static let openable: Set<String> = ["http", "https", "mailto", "tel"]

    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openable.contains(scheme)
    }
}

/// Whether the link the reader sees and the link they would get are the same thing.
///
/// The cheapest anti-phishing control there is, and the web client has a whole detector for
/// it. Ours runs in Swift on text collected during the rewrite, because a cancelled
/// navigation hands us a URL and nothing else — by the time WebKit asks, the anchor's text
/// is gone.
nonisolated enum LinkDisagreement {
    /// What to do with a click.
    enum Verdict: Equatable, Sendable {
        /// Hand it to the browser.
        case open
        /// Ask first, showing both the text and the host it actually goes to.
        case confirm(shown: String, target: String)
    }

    /// - Parameters:
    ///   - text: the anchor's visible text, as the rewriter collected it.
    ///   - target: where the anchor points.
    static func verdict(text: String?, target: URL) -> Verdict {
        guard let host = target.host()?.lowercased() else { return .open }

        // A hostname nobody can read is worth a question on its own: `xn--80ak6aa92e.com`
        // renders as apple.com in most fonts.
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            return .confirm(shown: text ?? host, target: host)
        }

        guard let text, let claimed = claimedHost(in: text) else { return .open }
        if matches(claimed: claimed, host: host) { return .open }
        return .confirm(shown: text, target: host)
    }

    /// The host a piece of link text claims to go to, if it claims one at all.
    ///
    /// Most link text is "Shop now" and claims nothing, which is the case that must not ask
    /// a question. Text that looks like a domain, a URL or an email address claims one.
    static func claimedHost(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count < 200 else { return nil }

        if let url = URL(string: trimmed), let host = url.host()?.lowercased(), host.contains(".") {
            return host
        }
        // `mail.example.com/login`, `www.example.com` and `sookie@example.com` all name a
        // host without spelling a scheme.
        let candidate = trimmed.split(whereSeparator: { $0 == "/" || $0 == "@" || $0 == " " }).last.map(String.init)
        guard let candidate else { return nil }
        let head = candidate.split(separator: "?").first.map(String.init) ?? candidate
        guard head.contains("."), !head.hasSuffix("."), head.allSatisfy(isHostCharacter) else { return nil }
        guard let suffix = head.split(separator: ".").last, suffix.count >= 2,
            suffix.allSatisfy({ $0.isLetter })
        else { return nil }
        return head
    }

    /// Equal, or one a subdomain of the other. `links.example.com` for text saying
    /// `example.com` is the ordinary shape of a marketing mail and not a lie.
    static func matches(claimed: String, host: String) -> Bool {
        claimed == host || host.hasSuffix("." + claimed) || claimed.hasSuffix("." + host)
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "-"
    }
}
