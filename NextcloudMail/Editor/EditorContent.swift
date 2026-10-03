// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// What a paragraph *is*, carried as one custom attribute on every character of it.
///
/// Block identity is explicit rather than inferred from fonts and indents, so "is this a
/// heading" has a single answer for the serialiser, the toolbar state and remove-format
/// ([ADR-0073](../../docs/decisions/0073-editor-canonical-html.md)).
nonisolated struct EditorBlock: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case paragraph
        /// 1–3; the serialiser clamps anything else back to a paragraph.
        case heading(Int)
        case listItem(EditorListKind)
    }

    var kind: Kind = .paragraph
    /// Inside a `<blockquote>`. Orthogonal to the kind, so a quoted heading survives.
    var isQuoted = false

    static let paragraph = EditorBlock()
}

nonisolated enum EditorListKind: Hashable, Sendable {
    case unordered
    case ordered
}

/// An inline image. `src` keeps the original `data:` URL byte-for-byte: the image is decoded
/// for display but never re-encoded, because a PNG round-tripped through `NSImage` is not
/// the same bytes and the round trip must be.
nonisolated struct EditorImage: Hashable, Sendable {
    var src: String
    var width: Int?
}

extension NSAttributedString.Key {
    /// Value: ``EditorBlock``.
    static let editorBlock = NSAttributedString.Key("NCMEditorBlock")
    /// Value: ``EditorImage``, on the attachment character it describes.
    static let editorImage = NSAttributedString.Key("NCMEditorImage")
}

/// The fonts the fixed tag set implies, derived from one base font.
///
/// A heading carries its size in the element, so a run whose font is exactly the heading's
/// derived font emits no inline tags — the comparison happens here and only here.
struct EditorFontMetrics {
    let baseFont: NSFont

    /// The size the account settings will eventually feed in (WS-39); until then, the one
    /// the message view also uses for plain bodies.
    static let defaultBaseFont = NSFont.systemFont(ofSize: 13)

    /// CSS's default h1–h3 ratios, rounded to whole points so the px round trip is exact.
    private static let headingFactors: [CGFloat] = [2.0, 1.5, 1.17]

    init(baseFont: NSFont = EditorFontMetrics.defaultBaseFont) {
        self.baseFont = baseFont
    }

    /// The font a run is expected to have in the given block when no inline tag applies.
    func font(for block: EditorBlock) -> NSFont {
        guard case .heading(let level) = block.kind, (1...3).contains(level) else { return baseFont }
        let size = (baseFont.pointSize * Self.headingFactors[level - 1]).rounded()
        let sized = NSFontManager.shared.convert(baseFont, toSize: size)
        return NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
    }
}

/// Colour ↔ canonical `#rrggbb`, in sRGB.
///
/// Only colours the user set serialise. System colours are catalog colours — they are the
/// view's appearance, not document content — and a catalog colour returns nil here.
nonisolated enum EditorColor {
    static func css(from color: NSColor) -> String? {
        guard color.type != .catalog, let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// `#rgb`, `#rrggbb` or `rgb(r, g, b)`, the three shapes mail HTML actually contains.
    static func color(fromCSS value: String) -> NSColor? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            let digits: [Character]
            switch hex.count {
            case 3: digits = hex.flatMap { [$0, $0] }
            case 6: digits = Array(hex)
            default: return nil
            }
            var components: [CGFloat] = []
            for pair in stride(from: 0, to: 6, by: 2) {
                guard let byte = UInt8(String(digits[pair...pair + 1]), radix: 16) else { return nil }
                components.append(CGFloat(byte) / 255)
            }
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
        }
        if text.hasPrefix("rgb("), text.hasSuffix(")") {
            let numbers = text.dropFirst(4).dropLast()
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 3, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return NSColor(
                srgbRed: CGFloat(numbers[0]) / 255,
                green: CGFloat(numbers[1]) / 255,
                blue: CGFloat(numbers[2]) / 255,
                alpha: 1)
        }
        return nil
    }
}

/// Layout constants for how blocks *draw* in the editor. Presentation only: none of these
/// numbers reach the serialised HTML, which reads ``EditorBlock`` instead.
nonisolated enum EditorPresentation {
    static let quoteIndent: CGFloat = 20
    static let listIndent: CGFloat = 28

    /// The paragraph style a block draws with, keeping whatever alignment and writing
    /// direction the existing style carries — those two are content, not presentation.
    static func paragraphStyle(for block: EditorBlock, merging existing: NSParagraphStyle?) -> NSParagraphStyle {
        // NSMutableParagraphStyle's mutableCopy of a style is always an NSMutableParagraphStyle.
        let style = NSMutableParagraphStyle()
        if let existing {
            style.alignment = existing.alignment
            style.baseWritingDirection = existing.baseWritingDirection
        }
        style.textLists = []
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        if case .listItem(let kind) = block.kind {
            let marker: NSTextList.MarkerFormat = kind == .ordered ? .decimal : .disc
            style.textLists = [NSTextList(markerFormat: marker, options: 0)]
            style.headIndent = listIndent
            style.firstLineHeadIndent = listIndent
        }
        if block.isQuoted {
            style.headIndent += quoteIndent
            style.firstLineHeadIndent += quoteIndent
        }
        return style
    }
}
