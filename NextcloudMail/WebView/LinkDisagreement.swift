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
/// is gone. ``LinkVerdicts`` carries the answer from the rewrite to the click.
nonisolated enum LinkDisagreement {
    /// What to do with a click.
    enum Verdict: Equatable, Sendable {
        /// Hand it to the browser.
        case open
        /// Ask first, showing both the text and the host it actually goes to.
        case confirm(shown: String, target: String)
    }

    /// The most of an anchor's text, in UTF-8 bytes, that the rule reads.
    ///
    /// The rewriter stops collecting there and ``claimedHost(in:)`` refuses anything longer
    /// before it trims or lowercases, so neither can be made to do work in proportion to a
    /// sender's paragraph. A host plus a path fits with room to spare.
    static let textLimit = 512

    /// - Parameters:
    ///   - text: the anchor's visible text, as the rewriter collected it.
    ///   - target: where the anchor points.
    static func verdict(text: String?, target: URL) -> Verdict {
        guard let host = target.host()?.lowercased() else { return .open }
        return verdict(text: text, host: host)
    }

    /// The same rule against a host already worked out, which is what the rewriter has: the
    /// host WebKit will report, not the one a `URL` parse of the sender's spelling gives.
    static func verdict(text: String?, host: String) -> Verdict {
        let host = withoutTrailingDots(host.lowercased())

        // A hostname nobody can read is worth a question on its own: `xn--80ak6aa92e.com`
        // renders as apple.com in most fonts.
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            return .confirm(shown: text.flatMap { $0.isEmpty ? nil : $0 } ?? host, target: host)
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
        // Measured before anything walks the string, so the cap bounds the work as well as
        // the answer.
        guard text.utf8.count <= textLimit else { return nil }
        let lowered = text.lowercased()
        guard let token = lowered.split(whereSeparator: \.isWhitespace).last else { return nil }

        if let url = URL(string: String(token)), let host = url.host()?.lowercased(), host.contains(".") {
            return withoutTrailingDots(host)
        }
        // `paypal.com/signin`, `www.example.com?x=1`, `example.com:443`, `example.com.` and
        // `sookie@example.com` all name a host without spelling a scheme. The host is the
        // authority: what comes before the path, after any user, before any port.
        var authority = token
        if let scheme = authority.range(of: "://") { authority = authority[scheme.upperBound...] }
        if let end = authority.firstIndex(where: { "/?#\\".contains($0) }) { authority = authority[..<end] }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        let head = withoutTrailingDots(String(authority))

        guard head.contains("."), head.allSatisfy(isHostCharacter) else { return nil }
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

    /// `paypal.com.` is `paypal.com` to DNS, and to a reader.
    private static func withoutTrailingDots(_ host: String) -> String {
        var host = Substring(host)
        while host.hasSuffix(".") { host = host.dropLast() }
        return String(host)
    }
}

/// Where an `http(s)` link goes, spelled the one way both ends of the link gate agree on.
///
/// The rewriter reads an `href` as the sender wrote it. The navigation delegate is handed the
/// URL WebKit made of it, in WHATWG's canonical form: `https://login.evil.test` arrives as
/// `https://login.evil.test/`, `https://Login.Evil.test` lower-cased, `?a='b` as `?a=%27b`.
/// Both are put through this one function, so the two spellings meet (ADR-0106).
///
/// Every step either does what WebKit's parser does or merges spellings WebKit would keep
/// apart: the port, the user and the fragment are dropped, the path and query are compared
/// percent-decoded and lower-cased. Merging can only make a disagreement apply to more
/// clicks. Where the host WebKit will report cannot be predicted with certainty — anything
/// not plain ASCII after percent-decoding, an IPv6 literal, a number that is not a dotted
/// quad — there is no target at all, and ``LinkVerdicts`` treats the anchor as able to be
/// any link in the message.
nonisolated struct LinkTarget: Hashable, Sendable {
    /// Lower-case ASCII, no trailing dot: what `URL.host()` of WebKit's URL gives.
    let host: String
    /// The host, then the dot-resolved path and the query, decoded and lower-cased.
    let key: String

    init?(_ spelling: String) {
        guard var rest = Self.webRemainder(of: spelling) else { return nil }

        // WebKit skips any run of slashes, either way round, after `http:` — and none at all
        // is also a host: `https:evil.test` is `https://evil.test/`.
        while let first = rest.first, first == Byte.slash || first == Byte.backslash { rest = rest.dropFirst() }
        let authorityEnd =
            rest.firstIndex { $0 == Byte.slash || $0 == Byte.backslash || $0 == Byte.question || $0 == Byte.hash }
            ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        let tail = rest[authorityEnd...]

        if let at = authority.lastIndex(of: Byte.at) { authority = authority[authority.index(after: at)...] }
        guard authority.first != Byte.openBracket else { return nil }
        var hostBytes = authority
        if let colon = authority.firstIndex(of: Byte.colon) {
            guard authority[authority.index(after: colon)...].allSatisfy(Byte.isDigit) else { return nil }
            hostBytes = authority[..<colon]
        }
        guard let host = Self.canonicalHost(hostBytes) else { return nil }

        let pathEnd = tail.firstIndex { $0 == Byte.question || $0 == Byte.hash } ?? tail.endIndex
        var query: ArraySlice<UInt8> = []
        if pathEnd < tail.endIndex, tail[pathEnd] == Byte.question {
            let afterMark = tail[tail.index(after: pathEnd)...]
            query = afterMark[..<(afterMark.firstIndex(of: Byte.hash) ?? afterMark.endIndex)]
        }

        var located = Self.resolvedPath(tail[..<pathEnd])
        if !query.isEmpty {
            located.append(Byte.question)
            located.append(contentsOf: query)
        }
        self.host = host
        self.key = host + String(decoding: Self.percentDecoded(located[...]), as: UTF8.self).lowercased()
    }

    /// True for an `http:` or `https:` spelling, whether or not a target can be read from it.
    static func isWeb(_ spelling: String) -> Bool {
        webRemainder(of: spelling) != nil
    }

    // MARK: - Parsing

    private enum Byte {
        static let slash = UInt8(ascii: "/")
        static let backslash = UInt8(ascii: "\\")
        static let question = UInt8(ascii: "?")
        static let hash = UInt8(ascii: "#")
        static let at = UInt8(ascii: "@")
        static let colon = UInt8(ascii: ":")
        static let dot = UInt8(ascii: ".")
        static let percent = UInt8(ascii: "%")
        static let openBracket = UInt8(ascii: "[")
        /// Bytes WebKit refuses in a host, beyond controls, space and DEL.
        static let forbiddenInHost = Set("#%/:<>?@[\\]^|".utf8)

        static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

        static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
    }

    /// What follows `http:` or `https:`, after the clean-up WebKit does before it parses:
    /// tabs and newlines removed wherever they are, controls and spaces trimmed off the ends.
    private static func webRemainder(of spelling: String) -> ArraySlice<UInt8>? {
        var bytes = Array(spelling.utf8.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D })[...]
        while let first = bytes.first, first <= 0x20 { bytes = bytes.dropFirst() }
        while let last = bytes.last, last <= 0x20 { bytes = bytes.dropLast() }
        guard let colon = bytes.firstIndex(of: Byte.colon) else { return nil }
        let scheme = String(decoding: bytes[..<colon], as: UTF8.self).lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return bytes[bytes.index(after: colon)...]
    }

    /// The host as WebKit will serialise it, or nil when that cannot be said for certain.
    private static func canonicalHost(_ raw: ArraySlice<UInt8>) -> String? {
        var bytes = percentDecoded(raw)
        // Anything outside ASCII goes through IDNA, whose mapping table is not ours to
        // reproduce: `login。evil。test` becomes `login.evil.test`. Guessing wrong would let a
        // lying anchor share a key with an honest one, so this declines instead.
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F && !Byte.forbiddenInHost.contains($0) })
        else {
            return nil
        }
        bytes = bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        while bytes.last == Byte.dot { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }

        // A host whose last label is a number is an IPv4 address to WebKit, in decimal,
        // octal, hex or fewer than four parts: `3221225985` is `192.0.2.1`. Only the
        // dotted-quad spelling is passed through; the rest decline.
        let labels = bytes.split(separator: Byte.dot, omittingEmptySubsequences: false)
        if let last = labels.last, Self.isNumeric(last) {
            guard labels.count == 4, labels.allSatisfy(Self.isCanonicalOctet) else { return nil }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isNumeric(_ label: ArraySlice<UInt8>) -> Bool {
        if label.count >= 2, label.first == UInt8(ascii: "0"),
            label[label.index(after: label.startIndex)] | 0x20 == UInt8(ascii: "x")
        {
            return label.dropFirst(2).allSatisfy { Byte.hexValue($0) != nil }
        }
        return !label.isEmpty && label.allSatisfy(Byte.isDigit)
    }

    private static func isCanonicalOctet(_ label: ArraySlice<UInt8>) -> Bool {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy(Byte.isDigit) else { return false }
        if label.count > 1, label.first == UInt8(ascii: "0") { return false }
        return Int(String(decoding: label, as: UTF8.self)).map { $0 <= 255 } ?? false
    }

    /// The path with `.` and `..` resolved the way WebKit resolves them, including their
    /// `%2e` spellings, before anything is decoded: decoding first would turn `%2F` into a
    /// separator WebKit never saw.
    private static func resolvedPath(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        // The path starts at the separator that ended the authority, or is empty; either way
        // the first split piece is the nothing before the leading slash.
        let path = raw.map { $0 == Byte.backslash ? Byte.slash : $0 }
        let segments = path.split(separator: Byte.slash, omittingEmptySubsequences: false).dropFirst()
        var resolved: [ArraySlice<UInt8>] = []
        for (offset, segment) in segments.enumerated() {
            let isLast = offset == segments.count - 1
            let spelled = String(decoding: segment, as: UTF8.self).lowercased()
            if ["..", ".%2e", "%2e.", "%2e%2e"].contains(spelled) {
                if !resolved.isEmpty { resolved.removeLast() }
                if isLast { resolved.append([]) }
            } else if [".", "%2e"].contains(spelled) {
                if isLast { resolved.append([]) }
            } else {
                resolved.append(segment)
            }
        }
        var out: [UInt8] = [Byte.slash]
        out.append(contentsOf: resolved.joined(separator: [Byte.slash]))
        return out
    }

    /// `%XX` decoded once. A `%` not followed by two hex digits stays as it is, which is
    /// also what WebKit does with it.
    private static func percentDecoded(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == Byte.percent, raw.distance(from: index, to: raw.endIndex) >= 3,
                let high = Byte.hexValue(raw[index + 1]), let low = Byte.hexValue(raw[index + 2])
            {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(raw[index])
                index += 1
            }
        }
        return out
    }
}

/// What every anchor in one message said about where it goes, so a click can be judged from
/// its URL alone (ADR-0106).
///
/// A verdict is worked out per anchor as the rewriter closes it, and the first disagreeing
/// one is kept for its target and for its host. Two anchors on one `href` that say different
/// things therefore ask, whichever comes first: an honest footer link cannot vouch for a
/// lying one.
nonisolated struct LinkVerdicts: Equatable, Sendable {
    private var byTarget: [String: LinkDisagreement.Verdict] = [:]
    private var byHost: [String: LinkDisagreement.Verdict] = [:]
    /// Hosts claimed by the text of `http(s)` anchors whose target could not be predicted.
    /// Any click might be one of them, so each is checked against every click.
    private var unplacedClaims: [Claim] = []
    private var unplacedHosts: Set<String> = []

    private struct Claim: Equatable, Sendable {
        var host: String
        var text: String
    }

    /// - Parameters:
    ///   - text: the anchor's visible text, bounded by ``LinkDisagreement/textLimit``.
    ///   - href: the anchor's `href`, entity-decoded, as the document carries it.
    mutating func record(text: String, href: String) {
        if let target = LinkTarget(href) {
            let verdict = LinkDisagreement.verdict(text: text, host: target.host)
            Self.keep(verdict, at: target.key, in: &byTarget)
            Self.keep(verdict, at: target.host, in: &byHost)
        } else if LinkTarget.isWeb(href), let claimed = LinkDisagreement.claimedHost(in: text),
            unplacedHosts.insert(claimed).inserted
        {
            unplacedClaims.append(Claim(host: claimed, text: text))
        }
    }

    /// What to do with a click on `url`, which is the URL WebKit reports, not the `href`.
    func verdict(for url: URL) -> LinkDisagreement.Verdict {
        // `mailto:` and `tel:` name no host, so there is nothing to disagree with.
        guard LinkTarget.isWeb(url.absoluteString) else { return LinkDisagreement.verdict(text: nil, target: url) }
        let unknown = LinkDisagreement.Verdict.confirm(
            shown: url.absoluteString,
            target: url.host()?.lowercased() ?? url.absoluteString
        )
        guard let target = LinkTarget(url.absoluteString) else { return unknown }

        for claim in unplacedClaims where !LinkDisagreement.matches(claimed: claim.host, host: target.host) {
            return .confirm(shown: claim.text, target: target.host)
        }
        // The host table answers when WebKit resolved the path in a way this did not. Every
        // anchor is recorded, "Shop now" included, so finding nothing at all means the
        // click came from an anchor that was read differently from how WebKit read it, and
        // its text is unknown: ask rather than open.
        return byTarget[target.key] ?? byHost[target.host] ?? unknown
    }

    /// The first disagreement wins and stays; agreement only fills an empty slot.
    private static func keep(
        _ verdict: LinkDisagreement.Verdict,
        at key: String,
        in table: inout [String: LinkDisagreement.Verdict]
    ) {
        switch (table[key], verdict) {
        case (nil, _), (.open?, .confirm): table[key] = verdict
        default: break
        }
    }
}
