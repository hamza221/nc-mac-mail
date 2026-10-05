// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailTestSupport

@Suite("RequestMatcher")
struct RequestMatcherTests {
    private func request(
        method: String = "GET",
        path: String = "/remote.php/dav/",
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: "https://cloud.example.com\(path)")))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    @Test("DAV method matchers match their verb and nothing else")
    func davMethods() throws {
        let propfind = try request(method: "PROPFIND")
        #expect(RequestMatcher.propfind.matches(propfind))
        #expect(!RequestMatcher.report.matches(propfind))
        #expect(!RequestMatcher.mkcol.matches(propfind))
        #expect(!RequestMatcher.proppatch.matches(propfind))
        #expect(RequestMatcher.report.matches(try request(method: "REPORT")))
        #expect(RequestMatcher.mkcol.matches(try request(method: "MKCOL")))
        #expect(RequestMatcher.proppatch.matches(try request(method: "PROPPATCH")))
        // Case-insensitive, like every other method matcher.
        #expect(RequestMatcher.propfind.matches(try request(method: "propfind")))
    }

    @Test("depth matches the Depth header exactly")
    func depthHeader() throws {
        let listing = try request(method: "PROPFIND", headers: ["Depth": "1"])
        #expect(RequestMatcher.depth("1").matches(listing))
        #expect(!RequestMatcher.depth("0").matches(listing))
        #expect(!RequestMatcher.depth("1").matches(try request(method: "PROPFIND")))
    }

    @Test("header matches exact values and substrings, name case-insensitively")
    func headerMatching() throws {
        let put = try request(
            method: "PUT",
            headers: ["If-Match": "\"abc123\"", "Content-Type": "text/vcard; charset=utf-8"]
        )
        #expect(RequestMatcher.header("If-Match", "\"abc123\"").matches(put))
        #expect(RequestMatcher.header("if-match", "\"abc123\"").matches(put))
        #expect(!RequestMatcher.header("If-Match", "\"other\"").matches(put))
        #expect(RequestMatcher.header("Content-Type", contains: "text/vcard").matches(put))
        #expect(!RequestMatcher.header("Content-Type", contains: "application/xml").matches(put))
    }

    @Test("bodyContains pins a stub to one DAV report body")
    func bodyMatching() throws {
        let xml = "<?xml version=\"1.0\"?><d:sync-collection xmlns:d=\"DAV:\"/>"
        let report = try request(method: "REPORT", body: Data(xml.utf8))
        #expect(RequestMatcher.bodyContains("sync-collection").matches(report))
        #expect(!RequestMatcher.bodyContains("addressbook-multiget").matches(report))
        // No body at all: no match, no crash.
        #expect(!RequestMatcher.bodyContains("sync-collection").matches(try request(method: "REPORT")))
    }

    @Test("multipart matches on Content-Type prefix, any subtype")
    func multipartMatching() throws {
        let upload = try request(
            method: "POST",
            path: "/index.php/apps/mail/api/attachments",
            headers: ["Content-Type": "multipart/form-data; boundary=xyz"],
            body: Data(
                "--xyz\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"a.pdf\"\r\n\r\nbytes\r\n--xyz--\r\n"
                    .utf8)
        )
        #expect(RequestMatcher.multipart.matches(upload))
        #expect(!RequestMatcher.multipart.matches(try request(method: "POST")))

        let signed = try request(
            method: "POST",
            headers: ["Content-Type": "multipart/signed; boundary=sig"]
        )
        #expect(RequestMatcher.multipart.matches(signed))
    }

    @Test("multipartField finds the named form field and rejects the rest")
    func multipartFieldMatching() throws {
        let body = Data(
            "--xyz\r\nContent-Disposition: form-data; name=\"certificate\"; filename=\"c.pem\"\r\n\r\npem\r\n--xyz--\r\n"
                .utf8)
        let upload = try request(
            method: "POST",
            headers: ["Content-Type": "multipart/form-data; boundary=xyz"],
            body: body
        )
        #expect(RequestMatcher.multipartField(named: "certificate").matches(upload))
        #expect(!RequestMatcher.multipartField(named: "attachment").matches(upload))
        // The field name alone is not enough: a non-multipart body must not match, or a
        // JSON payload mentioning name="certificate" would fool the matcher.
        let json = try request(method: "POST", body: body)
        #expect(!RequestMatcher.multipartField(named: "certificate").matches(json))
    }

    @Test("DAV matchers compose with && like the originals")
    func composition() throws {
        let sync = try request(
            method: "REPORT",
            path: "/remote.php/dav/addressbooks/users/admin/contacts/",
            headers: ["Depth": "0"],
            body: Data("<d:sync-collection xmlns:d=\"DAV:\"/>".utf8)
        )
        let matcher = RequestMatcher.report && .depth("0") && .bodyContains("sync-collection")
        #expect(matcher.matches(sync))
        #expect(!(RequestMatcher.report && .depth("1")).matches(sync))
    }
}
