// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Markup reduced to the text a reader sees, for text that must never be rendered as HTML.
///
/// The translation of an HTML body comes back from the translation provider as markup, and
/// it did not pass through the server's purifier: the purifier ran on the body the mirror
/// holds, not on what a model wrote about it. So it is shown as text — every tag dropped,
/// `<style>` and `<script>` with their contents, entities decoded, block boundaries turned
/// into line breaks — and never reaches a web view.
nonisolated enum HTMLPlainText {
    /// Elements whose end, or whose self-closing start, is a line break in the text.
    private static let blocks: Set<String> = [
        "address", "article", "blockquote", "br", "dd", "div", "dl", "dt", "footer", "h1", "h2", "h3", "h4",
        "h5", "h6", "header", "hr", "li", "ol", "p", "pre", "section", "table", "tr", "ul",
    ]
    /// Elements whose contents are not text a reader sees.
    private static let hidden: Set<String> = ["head", "script", "style", "title"]

    static func text(of html: String) -> String {
        var output = ""
        var hiddenDepth = 0
        var scanner = HTMLScanner(html)
        while let token = scanner.next() {
            switch token {
            case .text(let text):
                guard hiddenDepth == 0 else { continue }
                let collapsed = collapsingWhitespace(HTMLEntities.decode(text))
                // Source indentation between blocks is not a line of its own.
                if output.isEmpty || output.hasSuffix("\n"), collapsed.allSatisfy({ $0 == " " }) { continue }
                output += collapsed
            case .startTag(let tag):
                if hidden.contains(tag.name), !tag.isSelfClosing {
                    hiddenDepth += 1
                } else if tag.name == "br" || tag.name == "hr" {
                    output += "\n"
                } else if blocks.contains(tag.name) {
                    breakLine(&output)
                }
            case .endTag(let name):
                if hidden.contains(name) {
                    hiddenDepth = max(0, hiddenDepth - 1)
                } else if blocks.contains(name) {
                    breakLine(&output)
                }
            case .comment:
                continue
            }
        }
        return
            output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Source formatting is not text: a newline inside a `<p>` is a space on screen.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
    }

    private static func breakLine(_ output: inout String) {
        guard !output.isEmpty, !output.hasSuffix("\n") else { return }
        output += "\n"
    }
}
