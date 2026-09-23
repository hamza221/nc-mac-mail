// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

@Suite("ncmail asset URLs")
struct MailAssetURLTests {
    @Test("a proxy URL survives the round trip, query and all")
    func roundTripsAProxyURL() throws {
        let original = try #require(
            URL(
                string:
                    "http://cloud.example.com/index.php/apps/mail/proxy?id=166&hmac=abc%2Bdef%3D&src=https%3A%2F%2Fcdn.test%2Fa.gif"
            )
        )
        let encoded = try #require(MailAssetURL.encode(original))

        #expect(encoded.scheme == "ncmail")
        #expect(encoded.host() == "asset")
        #expect(MailAssetURL.decode(encoded) == original)
    }

    @Test("the payload is URL-safe, so nothing downstream can renormalise it")
    func payloadIsURLSafe() throws {
        let original = try #require(URL(string: "http://cloud.example.com/a?b=c&d=e/f+g"))
        let encoded = try #require(MailAssetURL.encode(original))
        let payload = encoded.path().trimmingPrefix("/")

        #expect(payload.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test("anything that is not one of ours decodes to nothing")
    func rejectsForeignURLs() throws {
        let cases = [
            "https://evil.test/asset/aHR0cDovL2E",
            "ncmail://other/aHR0cDovL2E",
            "ncmail://asset/",
            "ncmail://asset/not-base64!!",
            "ncmail://asset/two/parts",
        ]
        for spelling in cases {
            let url = try #require(URL(string: spelling))
            #expect(MailAssetURL.decode(url) == nil, "\(spelling) should not decode")
        }
    }

    @Test("a payload that decodes to something other than an absolute URL is refused")
    func rejectsRelativePayloads() throws {
        let payload = MailAssetURL.base64url(Data("/etc/passwd".utf8))
        let url = try #require(URL(string: "ncmail://asset/\(payload)"))
        #expect(MailAssetURL.decode(url) == nil)
    }
}
