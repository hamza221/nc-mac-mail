// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Parses vCard 3.0 and 4.0 streams, plus the 2.1 habits that imports drag in:
/// bare type tokens and quoted-printable values with soft line breaks.
public enum VCardParser {
    public static func parse(_ data: Data) throws(DirectoryParseError) -> [VCard] {
        // Latin-1 as the fallback decode: it cannot fail, and a 2.1-era card
        // that is not UTF-8 is almost always Windows/Latin-1.
        let text =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    public static func parse(_ text: String) throws(DirectoryParseError) -> [VCard] {
        let lines = unfoldWithQuotedPrintable(text)
        var cards: [VCard] = []
        var current: [DirectoryProperty]?
        for line in lines {
            let property = try ContentLine.parse(line)
            if property.isNamed("BEGIN"), property.rawValue.caseInsensitiveCompare("VCARD") == .orderedSame {
                current = []
                continue
            }
            if property.isNamed("END"), property.rawValue.caseInsensitiveCompare("VCARD") == .orderedSame {
                guard let properties = current else { throw .missingBegin(expected: "VCARD") }
                cards.append(VCard(properties: properties))
                current = nil
                continue
            }
            // Content outside BEGIN/END is tolerated and dropped; some
            // exporters emit a stray trailing newline or a comment line.
            current?.append(property)
        }
        guard current == nil else { throw .unterminated(component: "VCARD") }
        return cards
    }

    /// Standard unfolding plus the vCard 2.1 special case: a quoted-printable
    /// value continues onto the next physical line when it ends with `=`, with
    /// no leading blank on the continuation. The trailing `=` (the soft break)
    /// is removed as the lines join, so the stored raw value decodes directly.
    static func unfoldWithQuotedPrintable(_ text: String) -> [String] {
        var logical: [String] = []
        var current: String?
        for physical in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = physical.first, first == " " || first == "\t" {
                current = (current ?? "") + physical.dropFirst()
                continue
            }
            if let line = current, isQuotedPrintable(line), line.hasSuffix("=") {
                current = String(line.dropLast()) + physical
                continue
            }
            if let line = current, !line.isEmpty { logical.append(line) }
            current = String(physical)
        }
        if let line = current, !line.isEmpty { logical.append(line) }
        return logical
    }

    /// True when the line's prefix (before the value) declares
    /// `ENCODING=QUOTED-PRINTABLE`. A substring check on the prefix is enough:
    /// the token cannot legally appear in a group or name.
    private static func isQuotedPrintable(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon].uppercased().contains("QUOTED-PRINTABLE")
    }
}
