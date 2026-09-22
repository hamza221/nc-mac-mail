// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NCMailNet

@Suite("ServerURL.normalize")
struct ServerURLTests {
    @Test("a bare host gets an https scheme")
    func bareHost() throws {
        let url = try ServerURL.normalize("cloud.example.com")
        #expect(url.absoluteString == "https://cloud.example.com")
    }

    @Test("an explicit https URL is unchanged")
    func explicitHTTPS() throws {
        let url = try ServerURL.normalize("https://cloud.example.com")
        #expect(url.absoluteString == "https://cloud.example.com")
    }

    @Test("a trailing slash is dropped")
    func trailingSlash() throws {
        let url = try ServerURL.normalize("https://cloud.example.com/")
        #expect(url.absoluteString == "https://cloud.example.com")
    }

    @Test("a path prefix survives, without a trailing slash")
    func pathPrefix() throws {
        let url = try ServerURL.normalize("https://example.com/nextcloud/")
        #expect(url.absoluteString == "https://example.com/nextcloud")
    }

    @Test("plain http is accepted, not upgraded")
    func plainHTTP() throws {
        let url = try ServerURL.normalize("http://nextcloud.local")
        #expect(url.absoluteString == "http://nextcloud.local")
        #expect(url.scheme == "http")
    }

    @Test("surrounding whitespace is trimmed")
    func whitespace() throws {
        let url = try ServerURL.normalize("  cloud.example.com  ")
        #expect(url.absoluteString == "https://cloud.example.com")
    }

    @Test("the host is lower-cased")
    func hostCasing() throws {
        let url = try ServerURL.normalize("Cloud.Example.COM")
        #expect(url.host == "cloud.example.com")
    }

    @Test("empty input is rejected")
    func empty() {
        #expect(throws: ServerURLError.empty) {
            try ServerURL.normalize("   ")
        }
    }

    @Test("a non-http(s) scheme is rejected")
    func wrongScheme() {
        #expect(throws: ServerURLError.unsupportedScheme) {
            try ServerURL.normalize("ftp://cloud.example.com")
        }
    }

    @Test("a scheme with no host is rejected")
    func missingHost() {
        #expect(throws: ServerURLError.missingHost) {
            try ServerURL.normalize("https://")
        }
    }
}
