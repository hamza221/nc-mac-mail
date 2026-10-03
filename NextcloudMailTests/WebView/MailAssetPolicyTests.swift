// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// The allowlist, asked directly. The rewriter and the scheme handler both call this, so a
/// case proven here is proven for both.
@Suite("Mail asset allowlist")
struct MailAssetPolicyTests {
    private static func url(_ spelling: String) throws -> URL {
        try #require(URL(string: spelling))
    }

    @Test("the two allowed shapes, on a server at the domain root")
    func allowsTheTwoShapes() throws {
        let server = try Self.url("https://cloud.example.com")
        #expect(
            MailAssetPolicy.classify(
                try Self.url("https://cloud.example.com/index.php/apps/mail/proxy?src=x&id=166&hmac=y"),
                server: server,
                messageRemoteId: 166
            ) == .proxiedRemoteImage
        )
        #expect(
            MailAssetPolicy.classify(
                try Self.url("https://cloud.example.com/index.php/apps/mail/api/messages/166/attachment/2.1"),
                server: server,
                messageRemoteId: 166
            ) == .inlineAttachment(attachmentId: "2.1")
        )
    }

    @Test("a server in a subdirectory, with and without the front controller")
    func handlesSubdirectoryInstalls() throws {
        let server = try Self.url("https://host.example/nextcloud")
        #expect(
            MailAssetPolicy.classify(
                try Self.url("https://host.example/nextcloud/apps/mail/proxy?src=x"),
                server: server,
                messageRemoteId: 1
            ) == .proxiedRemoteImage
        )
        #expect(
            MailAssetPolicy.classify(
                try Self.url("https://host.example/nextcloud/index.php/apps/mail/proxy?src=x"),
                server: server,
                messageRemoteId: 1
            ) == .proxiedRemoteImage
        )
        // The same path outside the installation's directory is a different application.
        #expect(
            MailAssetPolicy.classify(
                try Self.url("https://host.example/apps/mail/proxy?src=x"),
                server: server,
                messageRemoteId: 1
            ) == nil
        )
    }

    @Test("everything else is refused")
    func refusesEverythingElse() throws {
        let server = try Self.url("https://cloud.example.com")
        let refused = [
            // Another host that starts with ours.
            "https://cloud.example.com.evil.test/index.php/apps/mail/proxy?src=x",
            // Another port.
            "https://cloud.example.com:8443/index.php/apps/mail/proxy?src=x",
            // Another scheme.
            "http://cloud.example.com/index.php/apps/mail/proxy?src=x",
            // Our server, but not one of the two endpoints.
            "https://cloud.example.com/index.php/apps/mail/img/blocked-image.png",
            "https://cloud.example.com/remote.php/dav/files/lorelai/secret.txt",
            // An attachment of a different message.
            "https://cloud.example.com/index.php/apps/mail/api/messages/999/attachment/2",
            // A path that walks out of the attachment route.
            "https://cloud.example.com/index.php/apps/mail/api/messages/166/attachment/2/extra",
        ]
        for spelling in refused {
            #expect(
                MailAssetPolicy.classify(try Self.url(spelling), server: server, messageRemoteId: 166) == nil,
                "\(spelling) should be refused"
            )
        }
    }

    @Test("the default port is the same port")
    func defaultPortsMatch() throws {
        #expect(
            MailAssetPolicy.isOnServer(
                try Self.url("https://cloud.example.com:443/index.php"),
                server: try Self.url("https://cloud.example.com")
            )
        )
    }
}
