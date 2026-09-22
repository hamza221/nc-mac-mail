// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import Testing

@testable import NCMailNet

@Suite("Endpoint URLs")
struct EndpointTests {
    private let server = URL(string: "https://cloud.example.com")!

    @Test("the mail API prefix is applied")
    func buildsMailAPIPath() throws {
        let url = try Endpoint.accounts.url(relativeTo: server)
        #expect(url.absoluteString == "https://cloud.example.com/index.php/apps/mail/api/accounts")
    }

    @Test("an instance in a subdirectory keeps its prefix")
    func buildsAgainstSubdirectory() throws {
        let url = try Endpoint.accounts.url(relativeTo: URL(string: "https://example.com/nextcloud/")!)
        #expect(url.absoluteString == "https://example.com/nextcloud/index.php/apps/mail/api/accounts")
    }

    @Test("OCS routes hang off the server root, not the mail API")
    func buildsOCSPath() throws {
        let url = try Endpoint.capabilities.url(relativeTo: server)
        #expect(url.absoluteString == "https://cloud.example.com/ocs/v2.php/cloud/capabilities")
    }

    @Test("the message list carries its query")
    func buildsMessageListQuery() throws {
        let url = try Endpoint.messages(mailboxId: 5, cursor: 1_737_000_000, limit: 50).url(relativeTo: server)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "mailboxId", value: "5")))
        #expect(query.contains(URLQueryItem(name: "view", value: "singleton")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "50")))
        #expect(query.contains(URLQueryItem(name: "cursor", value: "1737000000")))
    }

    @Test("limit is clamped to the server's 1...100")
    func clampsLimit() throws {
        let high = try Endpoint.messages(mailboxId: 5, limit: 500).url(relativeTo: server)
        let low = try Endpoint.messages(mailboxId: 5, limit: 0).url(relativeTo: server)
        #expect(high.absoluteString.contains("limit=100"))
        #expect(low.absoluteString.contains("limit=1"))
    }

    @Test("a plus sign in an address survives as %2B")
    func escapesPlusInAddress() throws {
        let url = try Endpoint.avatar(email: "lorelai+mail@dragonfly.example").url(relativeTo: server)
        #expect(url.absoluteString.hasSuffix("/avatars/image/lorelai%2Bmail%40dragonfly.example"))
        #expect(!url.absoluteString.contains("+mail"))
    }

    @Test("an address with a slash or a space cannot escape its path segment")
    func escapesPathSeparators() throws {
        let url = try Endpoint.avatar(email: "a/../b c@example.com").url(relativeTo: server)
        #expect(url.absoluteString.hasSuffix("/avatars/image/a%2F..%2Fb%20c%40example.com"))
    }

    @Test("a MIME part path is escaped, dots and all")
    func escapesAttachmentId() throws {
        let url = try Endpoint.attachment(messageId: 42, attachmentId: "2.1").url(relativeTo: server)
        #expect(url.absoluteString.hasSuffix("/messages/42/attachment/2.1"))
    }

    @Test("the HTML endpoint always asks for the bare fragment")
    func alwaysAsksForPlainHTML() throws {
        let url = try Endpoint.messageHTML(id: 42).url(relativeTo: server)
        #expect(url.absoluteString.hasSuffix("/messages/42/html?plain=true"))
    }

    @Test("a filter term with a plus is not turned into a space")
    func escapesQueryPlus() throws {
        let url = try Endpoint.messages(mailboxId: 5, filter: "from:a+b@example.com").url(relativeTo: server)
        #expect(url.absoluteString.contains("filter=from%3Aa%2Bb%40example.com"))
    }

    @Test("reads and the sync call retry; mutations never do")
    func marksRetryability() {
        #expect(Endpoint.accounts.isRetryable)
        #expect(Endpoint.messages(mailboxId: 1).isRetryable)
        #expect(Endpoint.sync(mailboxId: 1).isRetryable)
        #expect(Endpoint.messageBody(id: 1).isRetryable)
        #expect(!Endpoint.setFlags(messageId: 1).isRetryable)
        #expect(!Endpoint.moveMessage(id: 1).isRetryable)
        #expect(!Endpoint.deleteMessage(id: 1).isRetryable)
        #expect(!Endpoint.moveThread(messageId: 1).isRetryable)
        #expect(!Endpoint.deleteThread(messageId: 1).isRetryable)
        #expect(!Endpoint.trustSender(email: "a@b.example").isRetryable)
    }

    @Test("no endpoint name carries anything a user wrote")
    func namesAreSafeToLog() {
        let names = [
            Endpoint.accounts.name,
            Endpoint.messages(mailboxId: 5).name,
            Endpoint.avatar(email: "lorelai@dragonfly.example").name,
            Endpoint.attachment(messageId: 1, attachmentId: "2").name,
            Endpoint.preference(key: "sort-order").name,
        ]
        for name in names {
            #expect(!name.contains("@"))
            #expect(!name.contains("/"))
            #expect(!name.isEmpty)
        }
    }
}

@Suite("Request bodies")
struct RequestBodyTests {
    private func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("the sync body spells the reserved word out as init")
    func encodesSyncRequest() throws {
        let text = try encode(SyncRequest(ids: [1, 2], lastMessageTimestamp: 99, initialise: true))
        #expect(text == #"{"ids":[1,2],"init":true,"lastMessageTimestamp":99,"sortOrder":"newest"}"#)
    }

    @Test("the move bodies use the two different parameter names")
    func encodesMoveRequests() throws {
        #expect(try encode(MoveMessageRequest(destFolderId: 15)) == #"{"destFolderId":15}"#)
        #expect(try encode(MoveThreadRequest(destMailboxId: 15)) == #"{"destMailboxId":15}"#)
    }

    @Test("the flag setter uses the unprefixed junk keys")
    func encodesFlagRequest() throws {
        let text = try encode(SetFlagsRequest(junk: true))
        #expect(text == #"{"flags":{"junk":true,"notjunk":false}}"#)
    }
}
