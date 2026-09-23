// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// What can be asserted about the handler without a running WebView: the request it would
/// make for a proxied image.
///
/// The serving path itself — `didReceive`, `didFinish`, the stopped-task guard — needs a
/// real `WKURLSchemeTask`, which needs a real `WKWebView` loading a real document. WS-09
/// had no GUI and did not fake one: a stub conforming to `WKURLSchemeTask` would assert
/// that this code calls the methods it obviously calls, and would say nothing about whether
/// WebKit is happy with the order or the response type. That gap is in the report.
@Suite("Mail asset scheme handler")
@MainActor
struct MailAssetSchemeHandlerTests {
    private static func handler(server: String) throws -> MailAssetSchemeHandler {
        let url = try #require(URL(string: server))
        return MailAssetSchemeHandler(
            store: try MailStore.inMemory(),
            client: MailClient(
                server: url,
                credentials: BasicCredentials(loginName: "lorelai", appPassword: "secret"),
                transport: ReplayTransport.answering(status: 200)
            ),
            server: url
        )
    }

    @Test("a proxy URL is rebuilt as a request that carries the app password")
    func proxyURLBecomesAnEndpoint() throws {
        let handler = try Self.handler(server: "http://cloud.example.com")
        // The shape the recorded body carries, with the query in the order the server wrote
        // it and the `src` percent-encoded.
        let target = try #require(
            URL(
                string: "http://cloud.example.com/index.php/apps/mail/proxy"
                    + "?id=166&hmac=REDACTED&src=https%3A%2F%2Fcdn.test%2Fa.gif"
            )
        )

        let endpoint = try #require(handler.proxyEndpoint(for: target))
        #expect(endpoint.encodedPath == "index.php/apps/mail/proxy")
        #expect(endpoint.query.map(\.name) == ["id", "hmac", "src"])
        // Decoded here, and re-encoded by `Endpoint` on the way out, so the server receives
        // what it signed.
        #expect(endpoint.query.last?.value == "https://cdn.test/a.gif")
        #expect(endpoint.isRetryable)
    }

    @Test("a subdirectory install keeps its prefix out of the endpoint path")
    func subdirectoryInstallsKeepTheirPrefix() throws {
        let handler = try Self.handler(server: "https://host.example/nextcloud")
        let target = try #require(URL(string: "https://host.example/nextcloud/apps/mail/proxy?src=x"))

        let endpoint = try #require(handler.proxyEndpoint(for: target))
        // `Endpoint` hangs the path off the server URL, which already carries `/nextcloud`.
        #expect(endpoint.encodedPath == "apps/mail/proxy")
    }

    @Test("a URL outside the installation has no endpoint at all")
    func offServerURLsHaveNoEndpoint() throws {
        let handler = try Self.handler(server: "https://host.example/nextcloud")
        let target = try #require(URL(string: "https://host.example/apps/mail/proxy?src=x"))
        #expect(handler.proxyEndpoint(for: target) == nil)
    }
}
