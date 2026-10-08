// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// Link detection for plain bodies, which runs on text the sender wrote.
///
/// Every body here is built inside `Task.detached`: that compiles only while
/// `PlainTextBody` is nonisolated, which is what keeps the data detector off the main actor.
@Suite("Plain text links")
struct PlainTextBodyTests {
    private static func build(_ text: String, signature: String? = nil) async -> PlainTextBody {
        await Task.detached { PlainTextBody(text: text, signature: signature) }.value
    }

    private static func links(_ attributed: AttributedString?) -> [String] {
        attributed?.runs.compactMap { $0.link?.absoluteString } ?? []
    }

    /// Filler that ends `before` units short of the detection limit, so a link can be put
    /// exactly where the limit falls.
    private static func padding(endingBeforeLimitBy before: Int) -> String {
        String(repeating: "x ", count: (PlainTextBody.linkDetectionLimit - before) / 2)
    }

    @Test("URLs and addresses in the text and the signature become links, and nothing else changes")
    func shortBodiesAreLinked() async {
        let text = "Hello, and https://example.com/x"
        let body = await Self.build(text, signature: "Lorelai, lorelai@example.com")

        #expect(Self.links(body.linkedText) == ["https://example.com/x"])
        #expect(Self.links(body.linkedSignature) == ["mailto:lorelai@example.com"])
        #expect(String(body.linkedText.characters) == text)
    }

    @Test("an empty signature draws nothing under the divider")
    func emptySignaturesAreDropped() async {
        #expect(await Self.build("Hi", signature: "").linkedSignature == nil)
        #expect(await Self.build("Hi").linkedSignature == nil)
    }

    @Test("a link that ends at the limit is linked, and one after it is not")
    func linksEndingAtTheLimitAreKept() async {
        let link = "https://end.example.com/"
        let text = Self.padding(endingBeforeLimitBy: link.utf16.count) + link + " https://beyond.example.com/"
        #expect(
            Self.padding(endingBeforeLimitBy: link.utf16.count).utf16.count + link.utf16.count
                == PlainTextBody.linkDetectionLimit)

        let body = await Self.build(text)

        #expect(Self.links(body.linkedText) == [link])
        #expect(String(body.linkedText.characters) == text)
    }

    @Test("a link the limit cuts through is not linked to the half before the cut")
    func linksAcrossTheLimitAreDropped() async {
        // Starts ten units before the limit; the detector would otherwise see "https://e".
        let text = Self.padding(endingBeforeLimitBy: 10) + "https://example.com/abcdef tail"

        let body = await Self.build(text)

        #expect(Self.links(body.linkedText).isEmpty)
        #expect(String(body.linkedText.characters) == text)
    }

    @Test("a link-dense body is linked up to the limit and shown whole past it")
    func linkDenseBodiesStopAtTheLimit() async {
        // The audit's payload: 760 KB of short links between non-ASCII text, which froze the
        // window for 9.5 s when the whole of it was searched on the main actor.
        let unit = "http://a.co \u{E9}\u{1F600} "
        let text = String(repeating: unit, count: 40_000)

        let body = await Self.build(text)

        #expect(Self.links(body.linkedText).count == PlainTextBody.linkDetectionLimit / unit.utf16.count)
        #expect(String(body.linkedText.characters) == text)
    }

    @Test("a body with no whitespace before the limit gets no links rather than a cut one")
    func unbrokenBodiesAreNotSearched() async {
        let text = String(repeating: "x", count: PlainTextBody.linkDetectionLimit * 2) + " https://example.com/"
        #expect(Self.links(await Self.build(text).linkedText).isEmpty)
    }
}
