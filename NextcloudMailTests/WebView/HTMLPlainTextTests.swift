// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailFixtures
import Testing

@testable import NextcloudMail

/// A translation of an HTML body is shown as text, so the markup has to go, all of it.
@Suite("HTML plain text")
struct HTMLPlainTextTests {
    @Test("tags, styles and scripts go; entities decode; blocks become lines")
    func reducesMarkupToText() {
        let html = """
            <style>p { color: red; }</style><p>Hello&nbsp;<b>Rory</b>,</p>
            <div>Line two<br>Line three</div><script>steal()</script><ul><li>a</li><li>b &amp; c</li></ul>
            """
        let text = HTMLPlainText.text(of: html)
        #expect(text == "Hello\u{a0}Rory,\nLine two\nLine three\na\nb & c")
        #expect(!text.contains("color"))
        #expect(!text.contains("steal"))
    }

    @Test("a tag the scanner cannot read stays visible text, never markup")
    func unreadableStaysText() {
        #expect(HTMLPlainText.text(of: "a < b and c > d").contains("a < b"))
    }

    @Test("the recorded marketing body reduces to its words, without its CSS")
    func recordedBody() throws {
        let html = String(decoding: try FixtureBytes.data("message-html-remote-images.html"), as: UTF8.self)
        let text = HTMLPlainText.text(of: html)
        #expect(!text.isEmpty)
        #expect(!text.contains("<"))
        #expect(!text.contains("@import"))
        #expect(!text.contains("{"))
    }
}
