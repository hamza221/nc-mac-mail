// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Attributed string → the plain-text body, for plain writing mode and for the strip that
/// "Turn off and remove formatting" performs.
///
/// Block structure degrades the way the web client degrades it: quotes become `> ` lines,
/// lists become `- ` / `1. ` lines, headings keep their text. Inline formatting and images
/// simply vanish — plain text has nowhere to put them.
enum PlainTextSerializer {

    static func text(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        var ordinal = 0
        var lastListKind: EditorListKind?
        var location = 0
        while true {
            let remaining = NSRange(location: location, length: string.length - location)
            let newline = string.range(of: "\n", options: [], range: remaining)
            let contentEnd = newline.location == NSNotFound ? string.length : newline.location
            let content = NSRange(location: location, length: contentEnd - location)

            var probe = content.location
            if content.length == 0 { probe = newline.location == NSNotFound ? NSNotFound : newline.location }
            var block = EditorBlock.paragraph
            if probe != NSNotFound, probe < string.length {
                block = text.attributes(at: probe, effectiveRange: nil)[.editorBlock] as? EditorBlock ?? .paragraph
            }

            var body = string.substring(with: content)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")

            switch block.kind {
            case .listItem(.ordered):
                ordinal = lastListKind == .ordered ? ordinal + 1 : 1
                lastListKind = .ordered
                body = "\(ordinal). " + body
            case .listItem(.unordered):
                lastListKind = .unordered
                body = "- " + body
            default:
                lastListKind = nil
            }
            if block.isQuoted {
                body = body.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }
                    .joined(separator: "\n")
            }
            lines.append(body)
            if newline.location == NSNotFound { break }
            location = newline.location + 1
        }
        return lines.joined(separator: "\n")
    }
}
