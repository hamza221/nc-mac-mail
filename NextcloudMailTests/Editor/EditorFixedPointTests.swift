// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing

@testable import NextcloudMail

/// HTML → editor → HTML is a fixed point for every construct in the fixed tag set, and one
/// pass makes any accepted input canonical (ADR-0073).
///
/// The inputs are written by hand on purpose: they are the *specification* of our own
/// serialiser's canonical grammar, not a decoder fixture of someone else's payload — the
/// same distinction `MessageHTMLRewriterTests` draws for its hostile fragment.
@Suite("Editor HTML fixed point")
struct EditorFixedPointTests {
    private static let baseFont = NSFont.systemFont(ofSize: 13)

    /// A real 1×1 transparent PNG, so the data-URL round trip exercises actual decoding.
    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private static func roundTrip(_ html: String) -> String {
        let imported = HTMLImporter.attributedString(fromHTML: html, baseFont: baseFont)
        return HTMLSerializer.html(from: imported, baseFont: baseFont)
    }

    private static func expectFixedPoint(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(roundTrip(html) == html, sourceLocation: sourceLocation)
    }

    /// Non-canonical input: one pass may rewrite it, the second must not.
    private static func expectIdempotent(
        _ html: String, becomes expected: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let once = roundTrip(html)
        #expect(once == expected, sourceLocation: sourceLocation)
        #expect(roundTrip(once) == once, sourceLocation: sourceLocation)
    }

    // MARK: - Every construct in the tag set

    @Test(
        "canonical constructs round-trip unchanged",
        arguments: [
            "<p>Hello</p>",
            "<p></p>",
            "<p>line<br>break</p>",
            "<p>a &amp; b &lt;c&gt;</p>",
            "<p>non\u{00A0}breaking</p>",
            "<p>two  spaces survive</p>",
            "<p><strong>bold</strong></p>",
            "<p><em>italic</em></p>",
            "<p><u>underlined</u></p>",
            "<p><s>struck</s></p>",
            "<p>H<sub>2</sub>O and x<sup>2</sup></p>",
            "<h1>Title</h1><h2>Sub</h2><h3>Minor</h3><p>body</p>",
            "<ul><li>one</li><li>two</li></ul>",
            "<ol><li>first</li><li>second</li></ol>",
            "<p>before</p><ul><li>item</li></ul><ol><li>step</li></ol><p>after</p>",
            "<blockquote><p>quoted</p><p>still quoted</p></blockquote><p>not quoted</p>",
            "<blockquote><h2>quoted heading</h2></blockquote>",
            "<blockquote><ul><li>quoted item</li></ul></blockquote>",
            "<p><a href=\"https://example.com/a?b=1&amp;c=2\">link</a></p>",
            "<p><a href=\"mailto:lorelai@dragonfly.example\">write</a></p>",
            "<p><span style=\"color:#ff0000\">red</span></p>",
            "<p><span style=\"background-color:#ffff00\">marked</span></p>",
            "<p><span style=\"font-family:Georgia\">serif</span></p>",
            "<p><span style=\"font-size:24px\">big</span> and <span style=\"font-size:9px\">small</span></p>",
            "<p><span style=\"color:#112233;background-color:#445566;font-family:Georgia;font-size:9px\">x</span></p>",
            "<p dir=\"rtl\">שלום</p>",
            "<p dir=\"ltr\">hello</p>",
            "<p style=\"text-align:left\">l</p><p style=\"text-align:center\">c</p>",
            "<p style=\"text-align:right\">r</p><p style=\"text-align:justify\">j</p>",
            "<p dir=\"rtl\" style=\"text-align:right\">aligned</p>",
            "<h2 dir=\"rtl\">heading direction</h2>",
            "<p><strong>bold <em>both</em></strong> plain</p>",
            "<p><a href=\"https://example.com\"><span style=\"color:#ff0000\"><strong><em><u><s><sup>all</sup></s></u></em></strong></span></a></p>",
        ])
    static func fixedPoint(_ html: String) {
        expectFixedPoint(html)
    }

    @Test("embedded image round-trips byte for byte")
    static func imageFixedPoint() {
        expectFixedPoint("<p><img src=\"data:image/png;base64,\(onePixelPNG)\" width=\"1\"></p>")
        expectFixedPoint("<p>before <img src=\"data:image/png;base64,\(onePixelPNG)\"> after</p>")
    }

    // MARK: - Canonicalisation of accepted non-canonical input

    @Test("uppercase and spacing canonicalise")
    static func caseAndSpacing() {
        expectIdempotent("<P >Hello</P>", becomes: "<p>Hello</p>")
        expectIdempotent("<p>a</p>\n  <p>b</p>", becomes: "<p>a</p><p>b</p>")
        expectIdempotent("<p>line\nwrapped\nsource</p>", becomes: "<p>line wrapped source</p>")
    }

    @Test("aliases map into the tag set")
    static func aliases() {
        expectIdempotent("<b>x</b><i>y</i>", becomes: "<p><strong>x</strong><em>y</em></p>")
        expectIdempotent("<p><strike>s</strike><del>d</del></p>", becomes: "<p><s>sd</s></p>")
        expectIdempotent("<div dir=\"RTL\">x</div>", becomes: "<p dir=\"rtl\">x</p>")
        expectIdempotent(
            "<p><span style=\" color : #F00 ; \">r</span></p>",
            becomes: "<p><span style=\"color:#ff0000\">r</span></p>")
        expectIdempotent(
            "<p><span style=\"font-family:'Times New Roman', serif\">t</span></p>",
            becomes: "<p><span style=\"font-family:Times New Roman\">t</span></p>")
    }

    @Test("inline nesting order is canonical")
    static func nestingOrder() {
        expectIdempotent("<p><em><strong>x</strong></em></p>", becomes: "<p><strong><em>x</em></strong></p>")
        expectIdempotent(
            "<p><u><a href=\"https://example.com\">x</a></u></p>",
            becomes: "<p><a href=\"https://example.com\"><u>x</u></a></p>")
    }

    @Test("structures outside the set flatten but settle")
    static func flattening() {
        expectIdempotent("<ul><li>a<ul><li>b</li></ul></li></ul>", becomes: "<ul><li>a</li><li>b</li></ul>")
        expectIdempotent(
            "<blockquote><blockquote><p>x</p></blockquote></blockquote>",
            becomes: "<blockquote><p>x</p></blockquote>")
        expectIdempotent("<table><tr><td>cell</td></tr></table>", becomes: "<p>cell</p>")
        expectIdempotent("<h4>too deep</h4>", becomes: "<p>too deep</p>")
    }

    // MARK: - The security edge: nothing fetchable survives import

    @Test("a remote image cannot enter the model")
    static func remoteImageDropped() {
        expectIdempotent("<p>x<img src=\"https://evil.example/t.png\"></p>", becomes: "<p>x</p>")
        expectIdempotent("<p><img src=\"HTTP://evil.example/t.png\"></p>", becomes: "<p></p>")
    }

    @Test("unsafe link schemes unwrap to text")
    static func unsafeLinks() {
        expectIdempotent("<p><a href=\"javascript:alert(1)\">x</a></p>", becomes: "<p>x</p>")
        expectIdempotent("<p><a href=\"&#106;avascript:alert(1)\">x</a></p>", becomes: "<p>x</p>")
        expectIdempotent("<p><a href=\"file:///etc/passwd\">x</a></p>", becomes: "<p>x</p>")
    }
}
