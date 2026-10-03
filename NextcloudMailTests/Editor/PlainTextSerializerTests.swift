// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing

@testable import NextcloudMail

/// How rich structure degrades to plain text — the plain writing mode and the destructive
/// half of "Turn off and remove formatting".
@Suite("Plain text serialiser")
struct PlainTextSerializerTests {
    private static func plain(_ html: String) -> String {
        let imported = HTMLImporter.attributedString(fromHTML: html, baseFont: NSFont.systemFont(ofSize: 13))
        return PlainTextSerializer.text(from: imported)
    }

    @Test("paragraphs and breaks become newlines")
    static func paragraphs() {
        #expect(plain("<p>a</p><p>b</p>") == "a\nb")
        #expect(plain("<p>a<br>b</p>") == "a\nb")
        #expect(plain("<p></p>") == "")
    }

    @Test("quotes become > prefixes, like the web client's plain replies")
    static func quotes() {
        #expect(plain("<blockquote><p>one</p><p>two</p></blockquote>") == "> one\n> two")
        #expect(plain("<blockquote><p>a<br>b</p></blockquote>") == "> a\n> b")
    }

    @Test("lists keep their markers, ordered lists count")
    static func lists() {
        #expect(plain("<ul><li>a</li><li>b</li></ul>") == "- a\n- b")
        #expect(plain("<ol><li>a</li><li>b</li></ol>") == "1. a\n2. b")
        #expect(plain("<ol><li>a</li></ol><p>x</p><ol><li>b</li></ol>") == "1. a\nx\n1. b")
    }

    @Test("inline formatting and images vanish without a trace")
    static func inlineDrops() {
        #expect(plain("<p><strong>a</strong> <em>b</em></p>") == "a b")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        #expect(plain("<p>a<img src=\"data:image/png;base64,\(png)\">b</p>") == "ab")
    }
}
