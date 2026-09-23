// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

@Suite("Link confirmation")
struct LinkDisagreementTests {
    private static func url(_ spelling: String) throws -> URL {
        try #require(URL(string: spelling))
    }

    @Test("text that claims no host asks no question")
    func ordinaryLinkTextOpens() throws {
        let target = try Self.url("https://ctrk.klclick.com/l/ABC123")
        for text in ["Shop now", "Hoodies", "Unsubscribe", "Click here", "", "3 new items"] {
            #expect(LinkDisagreement.verdict(text: text, target: target) == .open, "\(text) should not ask")
        }
    }

    @Test("text that names the host it goes to asks no question either")
    func matchingHostOpens() throws {
        #expect(
            LinkDisagreement.verdict(text: "example.com", target: try Self.url("https://example.com/x")) == .open
        )
        #expect(
            LinkDisagreement.verdict(
                text: "https://example.com/login", target: try Self.url("https://example.com/login"))
                == .open
        )
        // A marketing subdomain of the domain the text names is the ordinary shape.
        #expect(
            LinkDisagreement.verdict(text: "example.com", target: try Self.url("https://links.example.com/x")) == .open
        )
    }

    @Test("text naming one host and a target at another asks")
    func mismatchedHostConfirms() throws {
        let verdict = LinkDisagreement.verdict(
            text: "https://bank.example/login",
            target: try Self.url("https://bank.example.evil.test/login")
        )
        #expect(verdict == .confirm(shown: "https://bank.example/login", target: "bank.example.evil.test"))
    }

    @Test("an address as link text with an http target asks")
    func addressTextConfirms() throws {
        let verdict = LinkDisagreement.verdict(
            text: "security@bank.example",
            target: try Self.url("https://evil.test/reset")
        )
        #expect(verdict == .confirm(shown: "security@bank.example", target: "evil.test"))
    }

    @Test("a punycode host asks whatever the text says")
    func punycodeAlwaysConfirms() throws {
        let verdict = LinkDisagreement.verdict(text: "Shop now", target: try Self.url("https://xn--80ak6aa92e.com/x"))
        #expect(verdict == .confirm(shown: "Shop now", target: "xn--80ak6aa92e.com"))
    }

    @Test("only four schemes ever reach the system, whatever the message asks for")
    func onlyOpenableSchemesAreHandedOn() throws {
        for spelling in ["https://a.test/x", "http://a.test/x", "mailto:a@b.test", "tel:+4930123"] {
            #expect(MailLinkScheme.isOpenable(try Self.url(spelling)), "\(spelling) should open")
        }
        for spelling in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>bank</h1>",
            "ncmail://asset/abc",
            "ftp://a.test/x",
            "x-custom-handler://do-something",
        ] {
            #expect(!MailLinkScheme.isOpenable(try Self.url(spelling)), "\(spelling) should not open")
        }
    }

    @Test("a target with no host cannot disagree with anything")
    func hostlessTargetsOpen() throws {
        #expect(LinkDisagreement.verdict(text: "mail me", target: try Self.url("mailto:a@b.test")) == .open)
    }
}
