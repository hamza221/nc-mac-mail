// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing

@testable import NextcloudMail

/// What the importer puts *into* the attributed string — the attribute-level contract the
/// fixed-point suite exercises end to end.
@Suite("HTML importer")
struct HTMLImporterTests {
    private static let baseFont = NSFont.systemFont(ofSize: 13)

    private static func imported(_ html: String) -> NSAttributedString {
        HTMLImporter.attributedString(fromHTML: html, baseFont: baseFont)
    }

    @Test("paragraphs join on single separators with no trailing newline")
    static func paragraphJoining() {
        #expect(imported("<p>a</p><p>b</p>").string == "a\nb")
        #expect(imported("<p>a<br>b</p>").string == "a\u{2028}b")
        #expect(imported("").length == 0)
    }

    @Test("entities decode, including the numeric ones")
    static func entities() {
        #expect(imported("<p>a &amp; b</p>").string == "a & b")
        #expect(imported("<p>&#8364;5</p>").string == "€5")
        #expect(imported("<p>&nbsp;</p>").string == "\u{00A0}")
    }

    @Test("block identity is the custom attribute, not a font guess")
    static func blockAttribute() throws {
        let heading = imported("<h2>x</h2>")
        let block = try #require(heading.attribute(.editorBlock, at: 0, effectiveRange: nil) as? EditorBlock)
        #expect(block.kind == .heading(2))
        #expect(!block.isQuoted)

        let quoted = imported("<blockquote><p>x</p></blockquote>")
        let quotedBlock = try #require(quoted.attribute(.editorBlock, at: 0, effectiveRange: nil) as? EditorBlock)
        #expect(quotedBlock.kind == .paragraph)
        #expect(quotedBlock.isQuoted)
    }

    @Test("a heading's font is the derived heading font, so it serialises bare")
    static func headingFont() throws {
        let string = imported("<h1>x</h1>")
        let font = try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 26)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("list paragraphs carry their kind and a text list for the marker")
    static func listAttributes() throws {
        let string = imported("<ol><li>a</li></ol>")
        let block = try #require(string.attribute(.editorBlock, at: 0, effectiveRange: nil) as? EditorBlock)
        #expect(block.kind == .listItem(.ordered))
        let style = try #require(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.textLists.count == 1)
    }

    @Test("direction and alignment land in the paragraph style")
    static func directionAndAlignment() throws {
        let string = imported("<p dir=\"rtl\" style=\"text-align:right\">x</p>")
        let style = try #require(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.baseWritingDirection == .rightToLeft)
        #expect(style.alignment == .right)
    }

    @Test("a data image becomes an attachment that keeps the original bytes")
    static func dataImage() throws {
        let png =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let src = "data:image/png;base64,\(png)"
        let string = imported("<p><img src=\"\(src)\" width=\"1\"></p>")
        #expect(string.string == "\u{FFFC}")
        let image = try #require(string.attribute(.editorImage, at: 0, effectiveRange: nil) as? EditorImage)
        #expect(image.src == src)
        #expect(image.width == 1)
        let attachment = try #require(string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.image != nil)
    }

    @Test("whitespace-only text between blocks is dropped; inside a block it is content")
    static func whitespace() {
        #expect(imported("<p>a</p>   \n   <p>b</p>").string == "a\nb")
        #expect(imported("<p>a   b</p>").string == "a   b")
    }

    @Test("unknown markup keeps its text in reading order")
    static func unknownMarkup() {
        #expect(imported("<article><section>a</section><footer>b</footer></article>").string == "ab")
    }
}
