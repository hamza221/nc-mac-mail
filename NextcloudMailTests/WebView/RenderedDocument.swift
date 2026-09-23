// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// Reading a rendered document back the way WebKit would.
///
/// The security assertions in this suite are all one shape — "nothing in this document can
/// cause a load anywhere except our own scheme" — so the extraction happens once, here,
/// rather than as a different regular expression in each test.
enum RenderedDocument {
    /// Every URL in the document that would make the engine fetch something: `src`,
    /// `srcset`, `background`, `poster`, and `url(…)` in a style attribute or a style block.
    ///
    /// The lookbehind is load-bearing: without it `src="…"` also matches the tail of
    /// `data-original-src="…"`, which is the inert copy of a blocked URL and not a load.
    ///
    /// `href` is deliberately not in the list. A link is not a load: the navigation delegate
    /// cancels every navigation and hands the URL to the browser, so an anchor pointing at a
    /// click tracker is inert until the reader chooses it.
    static func loadableURLs(in document: String) throws -> [String] {
        var found: [String] = []
        for attribute in ["src", "srcset", "background", "poster"] {
            found += try matches(of: "(?<![-a-zA-Z0-9])\(attribute)=\"([^\"]*)\"", in: document)
        }
        found += try matches(of: "url\\(([^)]*)\\)", in: document)
        return
            found
            .flatMap { $0.split(separator: ",") }
            .compactMap { $0.split(separator: " ").first.map(String.init) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .filter { !$0.isEmpty }
    }

    /// Every start tag with the given name, taken from the rendered document with the same
    /// scanner that produced it — which is separately tested, and is the only HTML reader in
    /// this target.
    static func elements(_ name: String, in document: String) -> [HTMLStartTag] {
        HTMLScanner.tokens(of: document).compactMap { token in
            guard case .startTag(let tag) = token, tag.name == name else { return nil }
            return tag
        }
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func matches(of pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
