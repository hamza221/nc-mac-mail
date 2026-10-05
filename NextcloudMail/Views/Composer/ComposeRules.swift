// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One addressee, as the composer's chip fields hold it.
nonisolated struct ComposerAddress: Hashable, Sendable, Codable {
    var email: String
    var label: String?

    init(email: String, label: String? = nil) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// "Name <email>", or the bare address.
    var formatted: String {
        guard let label else { return email }
        return "\(label) <\(email)>"
    }

    var displayName: String { label ?? email }

    /// The web client's validity check is "something@something"; the server and SMTP are
    /// the final word, so this only keeps obvious typing from becoming a chip.
    var isValid: Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return !email.contains(where: \.isWhitespace) && !email.contains("<") && !email.contains(">")
    }

    /// Case-insensitive identity, which is how duplicates are refused (§6.4).
    var key: String { email.lowercased() }
}

// MARK: - Addresses in text

nonisolated enum AddressParser {
    /// Splits a pasted or typed list — `A <a@x>, "B, C" <b@x>; c@x` — into addresses, keeping
    /// names. Commas and semicolons inside quotes or angle brackets do not split.
    static func parseList(_ text: String) -> [ComposerAddress] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in text {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<" where !inQuotes: inAngle = true; current.append(character)
            case ">" where !inQuotes: inAngle = false; current.append(character)
            case "," where !inQuotes && !inAngle, ";" where !inQuotes && !inAngle, "\n":
                pieces.append(current)
                current = ""
            default: current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap(parseOne)
    }

    /// One `Name <email>`, `"Name" <email>`, `<email>` or bare `email`.
    static func parseOne(_ raw: String) -> ComposerAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = String(text[text.index(after: open)..<close])
            var name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            return ComposerAddress(email: email, label: name.isEmpty ? nil : name)
        }
        let email = text.hasPrefix("mailto:") ? String(text.dropFirst("mailto:".count)) : text
        return ComposerAddress(email: email)
    }
}

// MARK: - Subjects

/// "Re:" and "Fwd:" without stacking them on a subject that already carries one, in any of
/// the languages mail clients write them in (§6.1).
nonisolated enum SubjectPrefix {
    /// Reply prefixes, lowercased: English, German (AW), Nordic (SV, VS, Svar), Dutch
    /// (Antw), Polish (Odp), Turkish (YNT), Spanish/Portuguese (RE, RES), Italian (R),
    /// Chinese (回复, 回覆, 答复), Japanese (返信), Hebrew (השב), Greek (ΑΠ, ΣΧΕΤ).
    static let replyPrefixes: Set<String> = [
        "re", "aw", "sv", "svar", "vs", "antw", "odp", "ynt", "res", "r", "ref", "rif",
        "回复", "回覆", "答复", "返信", "השב", "απ", "σχετ", "atb", "vá",
    ]
    /// Forward prefixes: English (Fwd, Fw), German (WG), French (TR), Spanish (RV, Reenv),
    /// Portuguese (Enc), Dutch (Doorst), Italian (I), Polish (PD), Turkish (İLT), Chinese
    /// (转发, 轉寄), Japanese (転送).
    static let forwardPrefixes: Set<String> = [
        "fwd", "fw", "wg", "tr", "rv", "reenv", "enc", "doorst", "i", "pd", "ilt", "i̇lt",
        "转发", "轉寄", "転送", "továbbítás", "vb",
    ]

    static func reply(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if let first = leadingPrefix(trimmed), replyPrefixes.contains(first) { return trimmed }
        return "Re: \(trimmed)"
    }

    static func forward(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if let first = leadingPrefix(trimmed), forwardPrefixes.contains(first) { return trimmed }
        return "Fwd: \(trimmed)"
    }

    /// The lowercased token before the first colon (ASCII or full-width), ignoring a
    /// counter like `Re[2]:` or `AW(3):`; nil when the subject does not start with one.
    static func leadingPrefix(_ subject: String) -> String? {
        guard let colon = subject.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        var token = subject[..<colon].trimmingCharacters(in: .whitespaces)
        if let bracket = token.firstIndex(where: { $0 == "[" || $0 == "(" }),
            token.last == "]" || token.last == ")"
        {
            let counter = token[token.index(after: bracket)..<token.index(before: token.endIndex)]
            guard counter.allSatisfy(\.isNumber) else { return nil }
            token = String(token[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        guard !token.isEmpty, token.count <= 12, !token.contains(" ") else { return nil }
        return token.lowercased()
    }
}

// MARK: - Reply recipients

/// Who a reply goes to (§6.1), from the original's addresses and the user's own.
nonisolated enum ReplyRecipients {
    struct Original: Sendable {
        var from: [ComposerAddress]
        var to: [ComposerAddress]
        var cc: [ComposerAddress]
        var replyTo: [ComposerAddress]
        /// The original came through a mailing list, whose Reply-To points at the list.
        var isMailingList: Bool
    }

    struct Result: Equatable, Sendable {
        var to: [ComposerAddress]
        var cc: [ComposerAddress]
    }

    /// - Parameter own: every address the account sends as (the account and its aliases).
    static func build(_ original: Original, mode: ReplyMode, own: Set<String>) -> Result {
        let isOwn: (ComposerAddress) -> Bool = { own.contains($0.key) }
        let sentByMe = original.from.contains(where: isOwn)
        // Reply-To is honoured except on mailing lists, where it names the list and a
        // "reply to sender" would go to everyone.
        let sender = !original.replyTo.isEmpty && !original.isMailingList ? original.replyTo : original.from

        if mode == .followUp || sentByMe {
            // A reply to my own message goes to the people I sent it to; if I only wrote to
            // myself, it goes back to me.
            let recipients = original.to.filter { !isOwn($0) }
            if recipients.isEmpty {
                return Result(to: dedupe(original.to.isEmpty ? original.from : original.to), cc: [])
            }
            let cc = mode == .sender ? [] : original.cc.filter { !isOwn($0) }
            return Result(to: dedupe(recipients), cc: dedupe(cc, excluding: recipients))
        }

        switch mode {
        case .sender, .followUp:
            return Result(to: dedupe(sender), cc: [])
        case .all:
            let to = dedupe(sender + original.to.filter { !isOwn($0) })
            let cc = dedupe(original.cc.filter { !isOwn($0) }, excluding: to)
            return Result(to: to.isEmpty ? dedupe(sender) : to, cc: cc)
        }
    }

    static func dedupe(_ list: [ComposerAddress], excluding: [ComposerAddress] = []) -> [ComposerAddress] {
        var seen = Set(excluding.map(\.key))
        return list.filter { seen.insert($0.key).inserted }
    }
}

// MARK: - Quote and forward blocks

/// The text around the original that a reply or forward carries (§6.6).
nonisolated enum QuoteBlock {
    /// `"Name" email – <date>`, the web client's quote header.
    static func header(from: ComposerAddress?, date: Date, locale: Locale = .current) -> String {
        let when = date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
        guard let from else { return when }
        if let label = from.label { return "\"\(label)\" \(from.email) – \(when)" }
        return "\(from.email) – \(when)"
    }

    /// The reply quote, kept as the server's sanitised HTML inside `<blockquote type="cite">`
    /// (ADR-0065). `body` is already sanitised by the server; it is not re-escaped.
    static func replyHTML(header: String, body: String) -> String {
        "<p>\(escape(header))</p><blockquote type=\"cite\">\(body)</blockquote>"
    }

    /// The plain-text reply quote: the header, then every line prefixed "> ".
    static func replyPlain(header: String, body: String) -> String {
        let quoted = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\(header)\n\(quoted)"
    }

    struct ForwardFields: Sendable {
        var from: ComposerAddress?
        var to: [ComposerAddress]
        var cc: [ComposerAddress]
        var date: Date
        var subject: String
    }

    static func forwardHeaderLines(_ fields: ForwardFields, locale: Locale = .current) -> [String] {
        var lines = [String(localized: "-------- Forwarded message --------")]
        if let from = fields.from { lines.append(String(localized: "From: \(from.formatted)")) }
        lines.append(
            String(
                localized:
                    "Date: \(fields.date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale)))"))
        lines.append(String(localized: "Subject: \(fields.subject)"))
        if !fields.to.isEmpty {
            lines.append(String(localized: "To: \(fields.to.map(\.formatted).joined(separator: ", "))"))
        }
        if !fields.cc.isEmpty {
            lines.append(String(localized: "Cc: \(fields.cc.map(\.formatted).joined(separator: ", "))"))
        }
        return lines
    }

    static func forwardHTML(_ fields: ForwardFields, body: String) -> String {
        let header = forwardHeaderLines(fields).map(escape).joined(separator: "<br>")
        return "<p>\(header)</p><div>\(body)</div>"
    }

    static func forwardPlain(_ fields: ForwardFields, body: String) -> String {
        (forwardHeaderLines(fields) + ["", body]).joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}

// MARK: - Signature

nonisolated enum SignatureText {
    /// Plain mode prefixes the signature with the "-- " delimiter (§6.6), unless the user
    /// already wrote one.
    static func plain(_ signature: String) -> String {
        let trimmed = signature.trimmingCharacters(in: .newlines)
        if trimmed.hasPrefix("-- \n") || trimmed == "--" || trimmed.hasPrefix("--\n") { return trimmed }
        return "-- \n\(trimmed)"
    }

    /// Server signatures are HTML when they contain markup, text otherwise.
    static func isHTML(_ signature: String) -> Bool {
        signature.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
    }

    /// A signature with an image forces rich text (§6.5).
    static func hasImage(_ signature: String) -> Bool {
        signature.range(of: "<img", options: .caseInsensitive) != nil
    }

    /// The signature as HTML for the rich editor, delimiter included.
    static func html(_ signature: String) -> String {
        let body =
            isHTML(signature)
            ? signature
            : QuoteBlock.escape(signature).replacingOccurrences(of: "\n", with: "<br>")
        return "<p>-- </p>\(body)"
    }
}
