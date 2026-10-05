// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Attributed string → the one canonical HTML spelling
/// ([ADR-0073](../../docs/decisions/0073-editor-canonical-html.md)).
///
/// Not `NSAttributedString`'s HTML export, which emits CSS-heavy, Word-like markup
/// ([ADR-0065](../../docs/decisions/0065-native-rich-text-editor.md)). Everything here is
/// deterministic: fixed inline nesting order, fixed style-property order, packed blocks —
/// so `serialize(import(x)) == x` is a testable statement rather than a hope.
enum HTMLSerializer {

    static func html(from text: NSAttributedString, baseFont: NSFont = EditorFontMetrics.defaultBaseFont) -> String {
        let metrics = EditorFontMetrics(baseFont: baseFont)
        let paragraphs = split(text)
        var out = ""
        var openList: EditorListKind?
        var inQuote = false

        for paragraph in paragraphs {
            // Structural wrappers close before they open, innermost first.
            if let list = openList, !paragraph.wantsList(list) || paragraph.block.isQuoted != inQuote {
                out += list == .ordered ? "</ol>" : "</ul>"
                openList = nil
            }
            if inQuote, !paragraph.block.isQuoted {
                out += "</blockquote>"
                inQuote = false
            }
            if paragraph.block.isQuoted, !inQuote {
                out += "<blockquote>"
                inQuote = true
            }
            if case .listItem(let kind) = paragraph.block.kind, openList != kind {
                out += kind == .ordered ? "<ol>" : "<ul>"
                openList = kind
            }
            out += element(for: paragraph, in: text, metrics: metrics)
        }
        if let list = openList { out += list == .ordered ? "</ol>" : "</ul>" }
        if inQuote { out += "</blockquote>" }
        return out
    }

    // MARK: - Paragraphs

    private struct Paragraph {
        var contentRange: NSRange
        var block: EditorBlock
        var style: NSParagraphStyle?

        func wantsList(_ kind: EditorListKind) -> Bool {
            if case .listItem(kind) = block.kind { return true }
            return false
        }
    }

    /// Paragraphs are the text between `\n` separators: n blocks ↔ n−1 separators, so an
    /// empty document is one empty paragraph and there is no trailing-newline ambiguity.
    private static func split(_ text: NSAttributedString) -> [Paragraph] {
        let string = text.string as NSString
        var paragraphs: [Paragraph] = []
        var location = 0
        while true {
            let remaining = NSRange(location: location, length: string.length - location)
            let newline = string.range(of: "\n", options: [], range: remaining)
            let contentEnd = newline.location == NSNotFound ? string.length : newline.location
            let content = NSRange(location: location, length: contentEnd - location)
            // An empty paragraph's attributes live on its separator.
            var probe = content.location
            if content.length == 0 { probe = newline.location == NSNotFound ? NSNotFound : newline.location }
            var block = EditorBlock.paragraph
            var style: NSParagraphStyle?
            if probe != NSNotFound, probe < string.length {
                let attrs = text.attributes(at: probe, effectiveRange: nil)
                block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
                style = attrs[.paragraphStyle] as? NSParagraphStyle
            }
            paragraphs.append(Paragraph(contentRange: content, block: block, style: style))
            if newline.location == NSNotFound { break }
            location = newline.location + 1
        }
        return paragraphs
    }

    private static func element(
        for paragraph: Paragraph, in text: NSAttributedString, metrics: EditorFontMetrics
    ) -> String {
        let tag: String
        switch paragraph.block.kind {
        case .paragraph: tag = "p"
        case .heading(let level): tag = (1...3).contains(level) ? "h\(level)" : "p"
        case .listItem: tag = "li"
        }

        var attributes = ""
        switch paragraph.style?.baseWritingDirection {
        case .rightToLeft: attributes += " dir=\"rtl\""
        case .leftToRight: attributes += " dir=\"ltr\""
        default: break
        }
        switch paragraph.style?.alignment {
        case .left: attributes += " style=\"text-align:left\""
        case .center: attributes += " style=\"text-align:center\""
        case .right: attributes += " style=\"text-align:right\""
        case .justified: attributes += " style=\"text-align:justify\""
        default: break
        }

        return "<\(tag)\(attributes)>" + inlineContent(of: paragraph, in: text, metrics: metrics) + "</\(tag)>"
    }

    // MARK: - Inline runs

    /// The canonical wrappers, outermost first. Adjacent runs diff against each other, so
    /// `<strong>a <em>b</em></strong>` stays one `strong`.
    private enum InlineTag: Equatable {
        case link(String)
        case span(String)
        case strong
        case em
        case underline
        case strike
        case sub
        case sup

        var opening: String {
            switch self {
            case .link(let href): "<a href=\"\(HTMLEntities.escapeAttribute(href))\">"
            case .span(let style): "<span style=\"\(HTMLEntities.escapeAttribute(style))\">"
            case .strong: "<strong>"
            case .em: "<em>"
            case .underline: "<u>"
            case .strike: "<s>"
            case .sub: "<sub>"
            case .sup: "<sup>"
            }
        }

        var closing: String {
            switch self {
            case .link: "</a>"
            case .span: "</span>"
            case .strong: "</strong>"
            case .em: "</em>"
            case .underline: "</u>"
            case .strike: "</s>"
            case .sub: "</sub>"
            case .sup: "</sup>"
            }
        }
    }

    private static func inlineContent(
        of paragraph: Paragraph, in text: NSAttributedString, metrics: EditorFontMetrics
    ) -> String {
        guard paragraph.contentRange.length > 0 else { return "" }
        let expected = metrics.font(for: paragraph.block)
        var out = ""
        var open: [InlineTag] = []

        func transition(to wanted: [InlineTag]) {
            var common = 0
            while common < open.count, common < wanted.count, open[common] == wanted[common] { common += 1 }
            for tag in open[common...].reversed() { out += tag.closing }
            for tag in wanted[common...] { out += tag.opening }
            open = wanted
        }

        text.enumerateAttributes(in: paragraph.contentRange) { attrs, range, _ in
            let runText = (text.string as NSString).substring(with: range)
            if let image = attrs[.editorImage] as? EditorImage {
                transition(to: wrappers(for: attrs, expected: expected))
                var img = "<img src=\"\(HTMLEntities.escapeAttribute(image.src))\""
                if let width = image.width { img += " width=\"\(width)\"" }
                out += img + ">"
                return
            }
            // A stray attachment character with no image payload is display-only.
            let visible = runText.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !visible.isEmpty else { return }
            transition(to: wrappers(for: attrs, expected: expected))
            out += escapeText(visible).replacingOccurrences(of: "\u{2028}", with: "<br>")
        }
        transition(to: [])
        return out
    }

    private static func wrappers(for attrs: [NSAttributedString.Key: Any], expected: NSFont) -> [InlineTag] {
        var tags: [InlineTag] = []
        if let link = attrs[.link] {
            let href = (link as? URL)?.absoluteString ?? link as? String
            if let href { tags.append(.link(href)) }
        }

        let font = attrs[.font] as? NSFont ?? expected
        var style: [String] = []
        if let color = attrs[.foregroundColor] as? NSColor, let css = EditorColor.css(from: color) {
            style.append("color:\(css)")
        }
        if let color = attrs[.backgroundColor] as? NSColor, let css = EditorColor.css(from: color) {
            style.append("background-color:\(css)")
        }
        if let family = font.familyName, family != expected.familyName {
            style.append("font-family:\(family)")
        }
        if Int(font.pointSize.rounded()) != Int(expected.pointSize.rounded()) {
            style.append("font-size:\(Int(font.pointSize.rounded()))px")
        }
        if !style.isEmpty { tags.append(.span(style.joined(separator: ";"))) }

        let traits = font.fontDescriptor.symbolicTraits
        let expectedTraits = expected.fontDescriptor.symbolicTraits
        if traits.contains(.bold), !expectedTraits.contains(.bold) { tags.append(.strong) }
        if traits.contains(.italic), !expectedTraits.contains(.italic) { tags.append(.em) }
        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { tags.append(.underline) }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { tags.append(.strike) }
        switch attrs[.superscript] as? Int ?? 0 {
        case ..<0: tags.append(.sub)
        case 1...: tags.append(.sup)
        default: break
        }
        return tags
    }

    /// Text escapes `&`, `<`, `>` and nothing else; U+00A0 stays a raw character, and
    /// consecutive spaces are the user's bytes, not ours to collapse.
    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
