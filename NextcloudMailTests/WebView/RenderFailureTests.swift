// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import Testing

@testable import NextcloudMail

/// The render path is where an error object can carry mail, so what it logs is asserted
/// rather than reviewed.
@Suite("Render failure labels")
struct RenderFailureTests {
    @Test("a transport failure does not log the URL it failed on")
    func transportErrorsLoseTheirURL() throws {
        // What the system's networking layer hands back when a request fails: the failing
        // URL is in the user info, and on the image path that URL is a tracker's address
        // with the recipient's id in it. (The name of that class is not spelled here:
        // `.swiftlint.yml`'s `ncm_no_urlsession_outside_net` matches comments too.)
        let failing = try #require(URL(string: "https://tracker.example/pixel.gif?u=lorelai"))
        let underlying = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: failing])
        let label = RenderFailure.label(MailError.transport(underlying))

        #expect(label == "transport")
        #expect(!label.contains("tracker.example"))
        #expect(!label.contains("lorelai"))
    }

    @Test("an error the render path does not know is reduced to its type")
    func unknownErrorsAreReducedToTheirType() {
        struct Chatty: Error, CustomStringConvertible {
            var description: String { "INSERT INTO attachment VALUES ('secret.pdf')" }
        }
        let label = RenderFailure.label(Chatty())

        #expect(label == "Chatty")
        #expect(!label.contains("secret.pdf"))
    }

    @Test("a refusal says which rule fired and nothing about the URL")
    func refusalsNameTheRule() {
        #expect(RenderFailure.label(MailAssetError.refused(.remoteImagesBlocked)) == "refused: remoteImagesBlocked")
        #expect(RenderFailure.label(MailAssetError.refused(.offServer)) == "refused: offServer")
    }

    @Test("a server failure keeps the status and drops the message")
    func serverErrorsKeepOnlyTheStatus() {
        let label = RenderFailure.label(MailError.server(status: 500, message: "user@example.com not found"))
        #expect(label == "server(status: 500)")
        #expect(!label.contains("@"))
    }
}
