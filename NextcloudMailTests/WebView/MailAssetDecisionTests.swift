// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// `MailAssetSchemeHandler.decide`, the handler's whole allowlist as a pure function, with
/// one context (the screen) and several (a whole-thread printout, ADR-0085).
@Suite("Mail asset decisions")
struct MailAssetDecisionTests {
    private static let server = "https://cloud.example.com"

    /// Nil only for a path this file got wrong, which `decide` then refuses and the
    /// expectation fails on.
    private static func asset(_ path: String) -> URL? {
        URL(string: "\(server)/index.php/apps/mail/\(path)").flatMap(MailAssetURL.encode)
    }

    private static func context(
        local: Int64, remote: Int64, shows: Bool = false, ids: Set<String> = ["2"]
    )
        -> MailAssetSchemeHandler.Context
    {
        MailAssetSchemeHandler.Context(
            localMessageId: local, remoteMessageId: remote, showsRemoteImages: shows, inlineAttachmentIds: ids)
    }

    private static func decide(
        _ url: URL?, _ contexts: [MailAssetSchemeHandler.Context]
    )
        -> MailAssetSchemeHandler.Decision
    {
        guard let server = URL(string: server) else { return .refuse(.offServer) }
        return MailAssetSchemeHandler.decide(url, server: server, contexts: contexts)
    }

    @Test("one context: v1's rules exactly")
    func singleContext() throws {
        let screen = Self.context(local: 1, remote: 166)
        #expect(
            Self.decide(Self.asset("api/messages/166/attachment/2"), [screen])
                == .inlineAttachment(screen, attachmentId: "2"))
        #expect(Self.decide(Self.asset("api/messages/166/attachment/9"), [screen]) == .refuse(.unknownAttachment))
        #expect(Self.decide(Self.asset("api/messages/167/attachment/2"), [screen]) == .refuse(.otherMessage))
        #expect(Self.decide(Self.asset("proxy?src=x"), [screen]) == .refuse(.remoteImagesBlocked))
        #expect(
            Self.decide(Self.asset("proxy?src=x"), [Self.context(local: 1, remote: 166, shows: true)])
                == .proxiedRemoteImage)
        #expect(Self.decide(Self.asset("api/accounts"), [screen]) == .refuse(.notAnAllowedPath))
        #expect(Self.decide(URL(string: "https://evil.test/x"), [screen]) == .refuse(.notAnAssetURL))
        let evil = try #require(URL(string: "https://evil.test/apps/mail/proxy"))
        let offServer = try #require(MailAssetURL.encode(evil))
        #expect(Self.decide(offServer, [screen]) == .refuse(.offServer))
    }

    @Test("a printout serves each message's own inline images from its own rows, and no one else's")
    func severalContextsAttributeAttachments() throws {
        let first = Self.context(local: 1, remote: 166, ids: ["2"])
        let second = Self.context(local: 7, remote: 170, ids: ["3"])
        let contexts = [first, second]
        #expect(
            Self.decide(Self.asset("api/messages/166/attachment/2"), contexts)
                == .inlineAttachment(first, attachmentId: "2"))
        #expect(
            Self.decide(Self.asset("api/messages/170/attachment/3"), contexts)
                == .inlineAttachment(second, attachmentId: "3"))
        // Message 170's id under message 166 is still somebody else's attachment.
        #expect(Self.decide(Self.asset("api/messages/166/attachment/3"), contexts) == .refuse(.unknownAttachment))
        #expect(Self.decide(Self.asset("api/messages/999/attachment/2"), contexts) == .refuse(.otherMessage))
    }

    @Test("a printout's proxied images need at least one message with remote images shown")
    func severalContextsGateProxiedImages() throws {
        let blocked = [Self.context(local: 1, remote: 166), Self.context(local: 7, remote: 170)]
        #expect(Self.decide(Self.asset("proxy?src=x"), blocked) == .refuse(.remoteImagesBlocked))
        let oneShown = [Self.context(local: 1, remote: 166), Self.context(local: 7, remote: 170, shows: true)]
        #expect(Self.decide(Self.asset("proxy?src=x"), oneShown) == .proxiedRemoteImage)
    }

    @Test("no contexts serves nothing")
    func noContexts() throws {
        #expect(Self.decide(Self.asset("api/messages/166/attachment/2"), []) == .refuse(.notAnAllowedPath))
        #expect(Self.decide(Self.asset("proxy?src=x"), []) == .refuse(.notAnAllowedPath))
    }
}
