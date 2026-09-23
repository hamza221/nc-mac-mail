// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A token of the server's sanitised fragment.
///
/// Enough of an HTML tokeniser to rewrite attributes and no more. It is not a parser: there
/// is no tree, no implied end tags and no error recovery, because the input is HTMLPurifier
/// output — balanced, quoted and already stripped of the shapes a real parser exists to
/// survive ([ADR-0009](../../docs/decisions/0009-sanitised-html-not-raw-mime.md)).
///
/// It still has to be strict about what it does not understand, because "the server already
/// sanitised it" is one server bug away from being false. Anything the scanner cannot read
/// as a tag it emits as text, which is escaped on the way out, so an unparsable construct
/// becomes visible characters rather than markup.
nonisolated enum HTMLToken: Equatable {
    case text(String)
    /// `<div class="x">` and `<img …/>`. `isSelfClosing` records the trailing slash.
    case startTag(HTMLStartTag)
    case endTag(name: String)
    /// `<!-- … -->`, `<!DOCTYPE …>` and processing instructions: copied through untouched.
    case comment(String)
}

/// One start tag, taken apart.
nonisolated struct HTMLStartTag: Equatable {
    /// Lowercased, so every comparison downstream is a plain `==`.
    var name: String
    var attributes: [HTMLAttribute]
    var isSelfClosing: Bool
}

/// One attribute, with its value already entity-decoded.
///
/// Decoded rather than raw because the value is compared against URL shapes: a proxy URL
/// arrives as `?id=166&amp;hmac=…`, and an allowlist that matched on the escaped form would
/// be matching a string the browser never sees.
nonisolated struct HTMLAttribute: Equatable {
    var name: String
    var value: String?
}

/// Splits a fragment into ``HTMLToken`` values.
///
/// Written as a cursor over `String.Index` rather than over an array of `Character`: a 5 MB
/// message is 5 million characters, and `Array(html)` would be roughly 80 MB of copy before
/// the first tag is read.
nonisolated struct HTMLScanner {
    private let html: String
    private var index: String.Index

    init(_ html: String) {
        self.html = html
        index = html.startIndex
    }

    /// Every token, in order.
    static func tokens(of html: String) -> [HTMLToken] {
        var scanner = HTMLScanner(html)
        var tokens: [HTMLToken] = []
        while let token = scanner.next() { tokens.append(token) }
        return tokens
    }

    mutating func next() -> HTMLToken? {
        guard index < html.endIndex else { return nil }
        if html[index] == "<" {
            if let token = readTag() { return token }
        }
        return readText()
    }

    // MARK: - Text

    private mutating func readText() -> HTMLToken {
        var text = ""
        // The first character is consumed unconditionally, so a `<` that failed to parse as
        // a tag cannot put the scanner in a loop that never advances.
        text.append(html[index])
        index = html.index(after: index)
        while index < html.endIndex, html[index] != "<" {
            text.append(html[index])
            index = html.index(after: index)
        }
        return .text(text)
    }

    // MARK: - Tags

    /// Reads one tag, or returns nil and leaves the cursor where it was.
    private mutating func readTag() -> HTMLToken? {
        let start = index
        var cursor = html.index(after: index)
        guard cursor < html.endIndex else { return nil }

        if html[cursor] == "!" || html[cursor] == "?" {
            return readCommentOrDeclaration(from: start)
        }

        var isEnd = false
        if html[cursor] == "/" {
            isEnd = true
            cursor = html.index(after: cursor)
        }

        var name = ""
        while cursor < html.endIndex, html[cursor].isLetter || html[cursor].isNumber || html[cursor] == "-" {
            name.append(html[cursor])
            cursor = html.index(after: cursor)
        }
        guard !name.isEmpty else { return nil }

        if isEnd {
            while cursor < html.endIndex, html[cursor] != ">" { cursor = html.index(after: cursor) }
            guard cursor < html.endIndex else { return nil }
            index = html.index(after: cursor)
            return .endTag(name: name.lowercased())
        }

        index = cursor
        var attributes: [HTMLAttribute] = []
        var isSelfClosing = false
        while index < html.endIndex {
            skipWhitespace()
            guard index < html.endIndex else { return nil }
            if html[index] == ">" {
                index = html.index(after: index)
                return .startTag(
                    HTMLStartTag(name: name.lowercased(), attributes: attributes, isSelfClosing: isSelfClosing))
            }
            if html[index] == "/" {
                isSelfClosing = true
                index = html.index(after: index)
                continue
            }
            guard let attribute = readAttribute() else {
                index = start
                return nil
            }
            attributes.append(attribute)
        }
        index = start
        return nil
    }

    private mutating func readCommentOrDeclaration(from start: String.Index) -> HTMLToken? {
        if html[start...].hasPrefix("<!--") {
            guard let end = html.range(of: "-->", range: html.index(start, offsetBy: 4)..<html.endIndex) else {
                return nil
            }
            let token = HTMLToken.comment(String(html[start..<end.upperBound]))
            index = end.upperBound
            return token
        }
        var cursor = start
        while cursor < html.endIndex, html[cursor] != ">" { cursor = html.index(after: cursor) }
        guard cursor < html.endIndex else { return nil }
        index = html.index(after: cursor)
        return .comment(String(html[start...cursor]))
    }

    private mutating func readAttribute() -> HTMLAttribute? {
        var name = ""
        while index < html.endIndex, !html[index].isWhitespace, html[index] != "=", html[index] != ">",
            html[index] != "/"
        {
            name.append(html[index])
            index = html.index(after: index)
        }
        guard !name.isEmpty else { return nil }

        skipWhitespace()
        guard index < html.endIndex, html[index] == "=" else {
            return HTMLAttribute(name: name.lowercased(), value: nil)
        }
        index = html.index(after: index)
        skipWhitespace()
        guard index < html.endIndex else { return nil }

        var raw = ""
        if html[index] == "\"" || html[index] == "'" {
            let quote = html[index]
            index = html.index(after: index)
            while index < html.endIndex, html[index] != quote {
                raw.append(html[index])
                index = html.index(after: index)
            }
            guard index < html.endIndex else { return nil }
            index = html.index(after: index)
        } else {
            while index < html.endIndex, !html[index].isWhitespace, html[index] != ">" {
                raw.append(html[index])
                index = html.index(after: index)
            }
        }
        return HTMLAttribute(name: name.lowercased(), value: HTMLEntities.decode(raw))
    }

    private mutating func skipWhitespace() {
        while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
    }
}

/// The entity handling the rewrite needs: decode enough to recognise a URL, escape enough
/// that nothing written back out can become markup.
nonisolated enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    /// Named and numeric references, decoded.
    ///
    /// Numeric references matter more than the named ones here: `&#106;avascript:` is the
    /// oldest way to hide a scheme from a filter that reads the raw attribute, and the
    /// scheme check downstream runs on the decoded value precisely so that trick has nothing
    /// to hide behind.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            var body = ""
            while cursor < text.endIndex, text[cursor] != ";", body.count < 10 {
                body.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == ";", let replacement = expand(body) else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            out.append(replacement)
            index = text.index(after: cursor)
        }
        return out
    }

    private static func expand(_ body: String) -> String? {
        if let named = named[body.lowercased()] { return named }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    /// For an attribute value written back inside double quotes.
    static func escapeAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
