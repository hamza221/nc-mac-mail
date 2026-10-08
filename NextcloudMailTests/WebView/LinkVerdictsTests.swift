// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// The link confirmation end to end: an anchor through the rewrite, a click through the URL
/// WebKit reports for it.
///
/// The fragments are adversarial input, written by hand because no real server sends them;
/// they are the audit's payloads. Every "reported" URL below is what WebKit's navigation
/// action carried for that `href` when the anchor was clicked in a `WKWebView` on macOS 26,
/// so the tests exercise the two spellings the gate has to reconcile.
@Suite("Link confirmation across the rewrite")
struct LinkVerdictsTests {
    private static func render(_ fragment: String) throws -> RenderedMessage {
        let policy = MessageRenderPolicy(
            server: try #require(URL(string: "https://cloud.example.com")),
            messageRemoteId: 166,
            showsRemoteImages: false
        )
        return MessageHTMLRewriter(policy: policy).render(fragment: fragment, baseFontSize: 13)
    }

    private static func verdict(_ fragment: String, clicking reported: String) throws -> LinkDisagreement.Verdict {
        try render(fragment).verdict(for: try #require(URL(string: reported)))
    }

    private static func asks(_ verdict: LinkDisagreement.Verdict) -> Bool {
        if case .confirm = verdict { return true }
        return false
    }

    // MARK: - Several anchors, one href

    @Test("an agreeing anchor before a lying one on the same href does not vouch for it")
    func agreeingAnchorCannotHideALie() throws {
        let footerFirst = """
            <p>Sent by <a href="https://login.evil.test/x">evil.test</a></p>
            <p><a href="https://login.evil.test/x">paypal.com</a></p>
            """
        #expect(
            try Self.verdict(footerFirst, clicking: "https://login.evil.test/x")
                == .confirm(shown: "paypal.com", target: "login.evil.test")
        )

        let hiddenFirst = """
            <a href="https://login.evil.test/x" style="display:none">login.evil.test</a>\
            <a href="https://login.evil.test/x">www.paypal.com</a>
            """
        #expect(
            try Self.verdict(hiddenFirst, clicking: "https://login.evil.test/x")
                == .confirm(shown: "www.paypal.com", target: "login.evil.test")
        )
    }

    // MARK: - Spellings WebKit rewrites

    @Test("an href WebKit reports in another spelling still finds its anchor's text")
    func nonCanonicalHrefsMeetWebKitsSpelling() throws {
        for (href, reported) in [
            ("https://login.evil.test", "https://login.evil.test/"),
            ("https://login.evil.test?s=1", "https://login.evil.test/?s=1"),
            ("https://Login.Evil.test/u", "https://login.evil.test/u"),
            ("https://login.evil.test/q?a='b", "https://login.evil.test/q?a=%27b"),
            ("https://login.evil.test:0443/a/../x#top", "https://login.evil.test/x#top"),
            ("https:\\\\login.evil.test\\x", "https://login.evil.test/x"),
        ] {
            let verdict = try Self.verdict("<a href=\"\(href)\">paypal.com</a>", clicking: reported)
            #expect(verdict == .confirm(shown: "paypal.com", target: "login.evil.test"), "\(href) should ask")
        }
    }

    @Test("an honest twin in WebKit's spelling does not vouch for a lying anchor WebKit rewrites onto it")
    func honestTwinCannotHideARewrittenLie() throws {
        // Each lying href is one WebKit turns into the honest one's URL, by a route the
        // rewriter cannot reproduce (IDNA mapping, IPv4 number forms) or must reproduce
        // exactly (dot segments after an encoded slash).
        for (lying, reported) in [
            ("https://login。evil。test/x", "https://login.evil.test/x"),
            ("https://3221225985/", "https://192.0.2.1/"),
            ("https://login.evil.test/a/b%2F../../x", "https://login.evil.test/a/x"),
        ] {
            let host = try #require(URL(string: reported)?.host())
            let fragment = "<a href=\"\(reported)\">\(host)</a> <a href=\"\(lying)\">paypal.com</a>"
            #expect(Self.asks(try Self.verdict(fragment, clicking: reported)), "\(lying) should ask")
        }
    }

    @Test("a web link the rewrite never recorded asks, because its text is unknown")
    func unrecordedWebLinkAsks() throws {
        let rendered = try Self.render("<p>No links here.</p>")
        #expect(Self.asks(rendered.verdict(for: try #require(URL(string: "https://login.evil.test/x")))))
        // A mail or phone link names no host, so it has nothing to disagree with.
        #expect(rendered.verdict(for: try #require(URL(string: "mailto:a@b.test"))) == .open)
    }

    @Test("ordinary marketing links still open, in either spelling")
    func shopNowStillOpens() throws {
        let fragment = """
            <a href="https://ctrk.klclick.com/l/ABC">Shop now</a>
            <a href="https://Ctrk.klclick.com">Hoodies</a>
            <a href="https://ctrk.klclick.com/l/DEF"><img alt="" src="cid:logo"></a>
            """
        for reported in [
            "https://ctrk.klclick.com/l/ABC", "https://ctrk.klclick.com/", "https://ctrk.klclick.com/l/DEF",
        ] {
            #expect(try Self.verdict(fragment, clicking: reported) == .open, "\(reported) should open")
        }
    }

    // MARK: - What the anchor text is taken to be

    @Test("an anchor's text is kept to the limit however much of it there is, and still claims its host")
    func anchorTextIsBoundedOnAppend() throws {
        // The audit's cost payload: the old cap was checked before an unbounded append, so
        // each `<br />x` copied the whole 100 KB again.
        let fragment =
            "<a href=\"https://login.evil.test/x\">paypal.com/"
            + String(repeating: "a", count: 100_000)
            + String(repeating: "<br />x", count: 4_000)
            + "</a>"
        let verdict = try Self.verdict(fragment, clicking: "https://login.evil.test/x")
        guard case .confirm(let shown, let target) = verdict else {
            Issue.record("expected a confirmation, got \(verdict)")
            return
        }
        #expect(target == "login.evil.test")
        #expect(shown.hasPrefix("paypal.com/"))
        #expect(shown.utf8.count <= LinkDisagreement.textLimit)
    }

    @Test("whitespace the reader never sees cannot push the text they do see past the limit")
    func whitespaceCollapsesBeforeTheLimit() throws {
        let padding = String(repeating: "\n    ", count: LinkDisagreement.textLimit)
        let verdict = try Self.verdict(
            "<a href=\"https://login.evil.test/x\">\(padding)<span>paypal.com</span>\(padding)</a>",
            clicking: "https://login.evil.test/x"
        )
        #expect(verdict == .confirm(shown: "paypal.com", target: "login.evil.test"))
    }

    @Test("an entity in the text is read as the character the reader sees")
    func entitiesAreDecoded() throws {
        let verdict = try Self.verdict(
            "<a href=\"https://login.evil.test/x\">paypal&#46;com</a>",
            clicking: "https://login.evil.test/x"
        )
        #expect(verdict == .confirm(shown: "paypal.com", target: "login.evil.test"))
    }
}
