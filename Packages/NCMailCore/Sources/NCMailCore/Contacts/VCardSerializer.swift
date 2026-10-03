// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// Re-emits a vCard. Lossless for everything untouched: a parsed property
/// carries its unfolded original line and that exact text is what goes out,
/// re-folded at 75 octets. Only properties this app created or replaced are
/// built from parts. ADR-0075.
public enum VCardSerializer {
    public static func serialize(_ card: VCard) -> Data {
        Data(text(for: card).utf8)
    }

    public static func serialize(_ cards: [VCard]) -> Data {
        Data(cards.map(text(for:)).joined().utf8)
    }

    static func text(for card: VCard) -> String {
        var lines: [String] = ["BEGIN:VCARD"]
        for property in card.properties {
            lines.append(ContentLine.fold(property.serializedLine))
        }
        lines.append("END:VCARD")
        return lines.map { $0 + "\r\n" }.joined()
    }
}
