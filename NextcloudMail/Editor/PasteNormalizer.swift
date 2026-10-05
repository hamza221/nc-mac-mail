// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Pasted RTF/RTFD, reduced to what the serialiser can say.
///
/// §6.5 wants pasted fonts and sizes preserved, so those survive — along with every other
/// attribute the fixed tag set can express. Everything else (kerning, shadows, ligature
/// hints, Word's tab stops) is dropped here rather than carried as invisible state the
/// round trip would lose anyway. RTFD attachments are files: they go to `onFile` and leave
/// no character behind.
enum PasteNormalizer {

    static func normalize(
        _ text: NSAttributedString,
        metrics: EditorFontMetrics,
        onFile: (EditorDroppedFile) -> Void
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
                    onFile(.data(data, preferredName: wrapper.preferredFilename ?? "Pasted file"))
                }
                return
            }
            let run = string.substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: allowed(attrs, metrics: metrics)))
        }
        applyBlocks(result, metrics: metrics)
        return result
    }

    private static func allowed(
        _ attrs: [NSAttributedString.Key: Any], metrics: EditorFontMetrics
    ) -> [NSAttributedString.Key: Any] {
        var clean: [NSAttributedString.Key: Any] = [:]

        var font = metrics.baseFont
        if let pasted = attrs[.font] as? NSFont {
            font = NSFontManager.shared.convert(font, toFamily: pasted.familyName ?? "")
            font = NSFontManager.shared.convert(font, toSize: pasted.pointSize)
            let traits = pasted.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        }
        clean[.font] = font

        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { clean[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 {
            clean[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let script = attrs[.superscript] as? Int, script != 0 { clean[.superscript] = script > 0 ? 1 : -1 }
        if let link = attrs[.link] { clean[.link] = link }
        if let color = attrs[.foregroundColor] as? NSColor, EditorColor.css(from: color) != nil {
            clean[.foregroundColor] = color
        }
        if let color = attrs[.backgroundColor] as? NSColor, EditorColor.css(from: color) != nil {
            clean[.backgroundColor] = color
        }
        return clean
    }

    /// Paragraph identity for the pasted text: lists survive as lists, everything else is a
    /// paragraph. Alignment and direction carry over; presentation is rebuilt from scratch.
    private static func applyBlocks(_ text: NSMutableAttributedString, metrics: EditorFontMetrics) {
        let string = text.string as NSString
        var location = 0
        while location < max(text.length, 1) {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if paragraph.length == 0 { break }
            let attrs = text.attributes(at: paragraph.location, effectiveRange: nil)
            var block = EditorBlock.paragraph
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle, let list = style.textLists.last {
                block.kind = .listItem(list.markerFormat == .decimal ? .ordered : .unordered)
            }
            text.addAttribute(.editorBlock, value: block, range: paragraph)
            let existing = attrs[.paragraphStyle] as? NSParagraphStyle
            let style = EditorPresentation.paragraphStyle(for: block, merging: existing)
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
            location = NSMaxRange(paragraph)
        }
    }
}
