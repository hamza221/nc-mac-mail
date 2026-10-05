// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// HTML → attributed string, over the fixed tag set and nothing else.
///
/// Built on `HTMLScanner.tokens(of:)` and `HTMLEntities.decode`, never on
/// `NSAttributedString(html:)` — that initialiser runs WebKit and can fetch remote
/// resources, and pasting into a composer must never make a network request
/// ([ADR-0065](../../docs/decisions/0065-native-rich-text-editor.md)). The same property
/// holds inside the model: only `data:` image sources import at all, so the resulting
/// string cannot hold a fetchable reference.
///
/// Anything outside the tag set imports as its text content; one pass through this importer
/// makes any input canonical for ``HTMLSerializer``
/// ([ADR-0073](../../docs/decisions/0073-editor-canonical-html.md)).
enum HTMLImporter {

    static func attributedString(fromHTML html: String, baseFont: NSFont) -> NSAttributedString {
        var builder = Builder(metrics: EditorFontMetrics(baseFont: baseFont))
        for token in HTMLScanner.tokens(of: html) {
            switch token {
            case .text(let text):
                builder.appendText(HTMLEntities.decode(text))
            case .startTag(let tag):
                builder.open(tag)
            case .endTag(let name):
                builder.close(name)
            case .comment:
                break
            }
        }
        return builder.finish()
    }

    /// The inline formatting in force while tags are open. A stack of these, one snapshot
    /// pushed per recognised start tag, restores exactly on the matching end tag.
    private struct InlineStyle {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        /// +1 sup, −1 sub, 0 neither.
        var script = 0
        var link: URL?
        var color: NSColor?
        var background: NSColor?
        var fontFamily: String?
        var fontSize: CGFloat?
    }

    private struct ImportedBlock {
        var block: EditorBlock
        var alignment: NSTextAlignment?
        var direction: NSWritingDirection?
        var content = NSMutableAttributedString()
    }

    private struct Builder {
        let metrics: EditorFontMetrics
        var blocks: [ImportedBlock] = []
        var current: ImportedBlock?
        var inlineStack: [(tag: String, saved: InlineStyle)] = []
        var inline = InlineStyle()
        var quoteDepth = 0
        var listStack: [EditorListKind] = []

        // MARK: - Tags

        mutating func open(_ tag: HTMLStartTag) {
            switch tag.name {
            case "p", "div":
                beginBlock(kind: .paragraph, tag: tag)
            case "h1", "h2", "h3":
                // The name is three characters, the third a digit; the scanner lowercased it.
                let level = Int(String(tag.name.dropFirst())) ?? 1
                beginBlock(kind: .heading(level), tag: tag)
            case "li":
                beginBlock(kind: .listItem(listStack.last ?? .unordered), tag: tag)
            case "ul":
                closeBlock()
                listStack.append(.unordered)
            case "ol":
                closeBlock()
                listStack.append(.ordered)
            case "blockquote":
                closeBlock()
                quoteDepth += 1
            case "br":
                appendRaw("\u{2028}")
            case "img":
                appendImage(tag)
            case "strong", "b":
                push(tag.name, tag.isSelfClosing) { $0.bold = true }
            case "em", "i":
                push(tag.name, tag.isSelfClosing) { $0.italic = true }
            case "u":
                push(tag.name, tag.isSelfClosing) { $0.underline = true }
            case "s", "strike", "del":
                push(tag.name, tag.isSelfClosing) { $0.strikethrough = true }
            case "sub":
                push(tag.name, tag.isSelfClosing) { $0.script = -1 }
            case "sup":
                push(tag.name, tag.isSelfClosing) { $0.script = 1 }
            case "a":
                push(tag.name, tag.isSelfClosing) { $0.link = Self.safeLink(tag["href"]) }
            case "span":
                push(tag.name, tag.isSelfClosing) { Self.applySpanStyle(tag["style"], to: &$0) }
            default:
                // Outside the tag set: the markup is dropped, the content stays.
                break
            }
        }

        mutating func close(_ name: String) {
            switch name {
            case "p", "div", "h1", "h2", "h3", "li":
                closeBlock()
            case "ul", "ol":
                closeBlock()
                if !listStack.isEmpty { listStack.removeLast() }
            case "blockquote":
                closeBlock()
                quoteDepth = max(0, quoteDepth - 1)
            default:
                // Pop to the matching start tag. Unmatched end tags are ignored, which is
                // also what makes self-closed inline tags harmless: nothing was pushed.
                guard let index = inlineStack.lastIndex(where: { $0.tag == name }) else { return }
                inline = inlineStack[index].saved
                inlineStack.removeSubrange(index...)
            }
        }

        mutating func push(_ tag: String, _ isSelfClosing: Bool, _ change: (inout InlineStyle) -> Void) {
            guard !isSelfClosing else { return }
            inlineStack.append((tag, inline))
            change(&inline)
        }

        // MARK: - Blocks

        mutating func beginBlock(kind: EditorBlock.Kind, tag: HTMLStartTag) {
            closeBlock()
            var block = ImportedBlock(block: EditorBlock(kind: kind, isQuoted: quoteDepth > 0))
            if let dir = tag["dir"] {
                switch dir.lowercased() {
                case "rtl": block.direction = .rightToLeft
                case "ltr": block.direction = .leftToRight
                default: break
                }
            }
            if let style = tag["style"] {
                switch Self.declarations(in: style)["text-align"] {
                case "left": block.alignment = .left
                case "center": block.alignment = .center
                case "right": block.alignment = .right
                case "justify": block.alignment = .justified
                default: break
                }
            }
            current = block
        }

        mutating func closeBlock() {
            guard let block = current else { return }
            blocks.append(block)
            current = nil
        }

        /// Text with no open block starts an implicit paragraph — `text<br>more` without a
        /// `<p>` is still mail HTML.
        mutating func ensureBlock() {
            if current == nil {
                var kind = EditorBlock.Kind.paragraph
                if let listKind = listStack.last { kind = .listItem(listKind) }
                current = ImportedBlock(block: EditorBlock(kind: kind, isQuoted: quoteDepth > 0))
            }
        }

        // MARK: - Content

        mutating func appendText(_ decoded: String) {
            // HTML newlines are formatting, not content: a run of them collapses to one
            // space inside a block and to nothing between blocks.
            let normalized = Self.collapseLineWhitespace(decoded)
            if current == nil, normalized.trimmingCharacters(in: .whitespaces).isEmpty { return }
            appendRaw(normalized)
        }

        mutating func appendRaw(_ text: String) {
            guard !text.isEmpty else { return }
            ensureBlock()
            current?.content.append(NSAttributedString(string: text, attributes: attributes()))
        }

        mutating func appendImage(_ tag: HTMLStartTag) {
            guard let src = tag["src"], src.hasPrefix("data:") else { return }
            ensureBlock()
            let width = tag["width"].flatMap(Int.init)
            let attachment = NSTextAttachment()
            if let image = Self.decodeDataURL(src) {
                attachment.image = image
                if let width, image.size.width > 0 {
                    let height = CGFloat(width) * image.size.height / image.size.width
                    attachment.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: height)
                }
            }
            let string = NSMutableAttributedString(attachment: attachment)
            var attrs = attributes()
            attrs[.editorImage] = EditorImage(src: src, width: width)
            string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
            current?.content.append(string)
        }

        func attributes() -> [NSAttributedString.Key: Any] {
            let block = current?.block ?? .paragraph
            var font = metrics.font(for: block)
            if let family = inline.fontFamily {
                font = NSFontManager.shared.convert(font, toFamily: family)
            }
            if let size = inline.fontSize {
                font = NSFontManager.shared.convert(font, toSize: size)
            }
            if inline.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }

            var attrs: [NSAttributedString.Key: Any] = [.font: font, .editorBlock: block]
            if inline.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if inline.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if inline.script != 0 { attrs[.superscript] = inline.script }
            if let link = inline.link { attrs[.link] = link }
            if let color = inline.color { attrs[.foregroundColor] = color }
            if let background = inline.background { attrs[.backgroundColor] = background }
            return attrs
        }

        // MARK: - Assembly

        mutating func finish() -> NSAttributedString {
            closeBlock()
            let result = NSMutableAttributedString()
            for (index, block) in blocks.enumerated() {
                let start = result.length
                result.append(block.content)
                if index < blocks.count - 1 {
                    // The separator carries the block's attributes so an empty paragraph
                    // still knows what it is.
                    result.append(NSAttributedString(string: "\n", attributes: separatorAttributes(for: block)))
                }
                let range = NSRange(location: start, length: result.length - start)
                let style = NSMutableParagraphStyle()
                let presentation = EditorPresentation.paragraphStyle(for: block.block, merging: nil)
                style.setParagraphStyle(presentation)
                if let alignment = block.alignment { style.alignment = alignment }
                if let direction = block.direction { style.baseWritingDirection = direction }
                if range.length > 0 { result.addAttribute(.paragraphStyle, value: style, range: range) }
            }
            return result
        }

        func separatorAttributes(for block: ImportedBlock) -> [NSAttributedString.Key: Any] {
            [.font: metrics.font(for: block.block), .editorBlock: block.block]
        }

        // MARK: - Parsing helpers

        static func collapseLineWhitespace(_ text: String) -> String {
            guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return text }
            var out = ""
            out.reserveCapacity(text.count)
            var inRun = false
            for character in text {
                if character == "\n" || character == "\r" || character == "\t" {
                    if !inRun { out.append(" ") }
                    inRun = true
                } else {
                    inRun = false
                    out.append(character)
                }
            }
            return out
        }

        /// `color:#f00; font-size: 13px` → ["color": "#f00", "font-size": "13px"].
        static func declarations(in style: String) -> [String: String] {
            var result: [String: String] = [:]
            for declaration in style.split(separator: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let name = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !value.isEmpty { result[name] = value }
            }
            return result
        }

        static func applySpanStyle(_ style: String?, to inline: inout InlineStyle) {
            guard let style else { return }
            let declarations = declarations(in: style)
            if let value = declarations["color"], let color = EditorColor.color(fromCSS: value) {
                inline.color = color
            }
            if let value = declarations["background-color"], let color = EditorColor.color(fromCSS: value) {
                inline.background = color
            }
            if let value = declarations["font-family"], let first = value.split(separator: ",").first {
                // The first family of the list, unquoted: the canonical form writes one.
                let family =
                    first
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !family.isEmpty { inline.fontFamily = family }
            }
            if let value = declarations["font-size"], value.hasSuffix("px"),
                let size = Int(value.dropLast(2).trimmingCharacters(in: .whitespaces))
            {
                inline.fontSize = CGFloat(size)
            }
        }

        /// Only schemes a mail body may carry. Anything else unwraps to plain text, which is
        /// the same fail-safe the message renderer applies.
        static func safeLink(_ href: String?) -> URL? {
            guard let href, let url = URL(string: href), let scheme = url.scheme?.lowercased(),
                ["http", "https", "mailto"].contains(scheme)
            else { return nil }
            return url
        }

        static func decodeDataURL(_ src: String) -> NSImage? {
            guard let comma = src.firstIndex(of: ",") else { return nil }
            let header = src[src.startIndex..<comma]
            guard header.lowercased().hasSuffix(";base64") else { return nil }
            guard let data = Data(base64Encoded: String(src[src.index(after: comma)...])) else { return nil }
            return NSImage(data: data)
        }
    }
}

extension HTMLStartTag {
    /// The first value of a named attribute, the shape every lookup here wants.
    subscript(name: String) -> String? {
        attributes.first(where: { $0.name == name })?.value
    }
}
