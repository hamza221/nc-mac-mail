// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailTestSupport
import Testing

@testable import NCMailNet

@Suite("Request shape")
struct RequestHeaderTests {
    @Test("every request carries the four headers and no cookies")
    func setsHeaders() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json("[]"))
        let client = MailClient.testing(transport: transport)
        _ = try await client.get(.accounts)

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
        #expect(request.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Nextcloud Mail (macOS)/test")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpMethod == "GET")
    }

    @Test("the session config refuses cookies, because one turns a 200 into a 412")
    func sessionRefusesCookies() {
        let configuration = URLSession.mail.configuration
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.httpMaximumConnectionsPerHost == 6)
    }

    @Test("a body is sent as JSON with a content type")
    func encodesBody() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json(#"{"newMessages":[],"changedMessages":[],"vanishedMessages":[]}"#))
        let client = MailClient.testing(transport: transport)
        _ = try await client.post(.sync(mailboxId: 5), body: SyncRequest(ids: [1], initialise: true))

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("\"init\":true"))
    }
}

@Suite("Status mapping")
struct StatusMappingTests {
    private func error(status: Int, body: String = "[]", headers: [String: String] = [:]) throws -> MailError? {
        let url = try #require(URL(string: "https://cloud.example.com"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        )
        return MailClient.error(for: response, data: Data(body.utf8), endpoint: "test")
    }

    @Test("200 is not an error")
    func mapsSuccess() throws {
        #expect(try error(status: 200) == nil)
    }

    @Test("202 is a sync still in progress")
    func mapsAccepted() throws {
        guard case .syncInProgress = try #require(try error(status: 202)) else {
            Issue.record("expected syncInProgress")
            return
        }
    }

    @Test("428 means the mailbox is not cached")
    func mapsPreconditionRequired() throws {
        guard case .mailboxNotCached = try #require(try error(status: 428)) else {
            Issue.record("expected mailboxNotCached")
            return
        }
    }

    @Test("400 carrying the fail envelope means the mailbox is not cached")
    func mapsFailEnvelope() throws {
        let body = #"{"status":"error","data":{"message":"Mailbox is not cached"}}"#
        guard case .mailboxNotCached = try #require(try error(status: 400, body: body)) else {
            Issue.record("expected mailboxNotCached")
            return
        }
    }

    @Test("400 with any other message stays a server error")
    func mapsOtherBadRequest() throws {
        guard case .server(let status, let message) = try #require(try error(status: 400, body: #"{"message":"nope"}"#))
        else {
            Issue.record("expected server")
            return
        }
        #expect(status == 400)
        #expect(message == "nope")
    }

    @Test(
        "the plain statuses map straight across",
        arguments: [(401, "unauthorized"), (403, "forbidden"), (404, "notFound"), (410, "notFound")]
    )
    func mapsPlainStatuses(status: Int, expected: String) throws {
        #expect(try #require(try error(status: status)).description == expected)
    }

    @Test("a 403 with the empty array the live server sends is still forbidden")
    func mapsLiveForbiddenBody() throws {
        // What `GET /api/messages/99999999/body` really answers: HTTP 403 with
        // a body of `[]`, not the documented error envelope.
        let body = String(decoding: try FixtureBytes.data("error-message-forbidden.json"), as: UTF8.self)
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
        guard case .forbidden = try #require(try error(status: 403, body: body)) else {
            Issue.record("expected forbidden")
            return
        }
    }

    @Test("429 carries the Retry-After the server asked for")
    func mapsRateLimitSeconds() throws {
        let mapped = try #require(try error(status: 429, headers: ["Retry-After": "17"]))
        guard case .rateLimited(let retryAfter) = mapped else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == .seconds(17))
    }

    @Test("503 is rate limiting too, and a missing Retry-After is nil")
    func mapsServiceUnavailable() throws {
        guard case .rateLimited(let retryAfter) = try #require(try error(status: 503)) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == nil)
    }

    @Test("a Retry-After date in the past is zero, not negative")
    func mapsRetryAfterDate() throws {
        let headers = ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]
        guard case .rateLimited(let retryAfter) = try #require(try error(status: 429, headers: headers)) else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == .zero)
    }

    @Test("500 is a server error with its status")
    func mapsServerError() throws {
        guard case .server(let status, _) = try #require(try error(status: 500)) else {
            Issue.record("expected server")
            return
        }
        #expect(status == 500)
    }
}

@Suite("Retries")
struct RetryTests {
    @Test("a GET retries three times and then throws")
    func retriesReads() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(status: 500))
        let recorder = DelayRecorder()
        let client = MailClient.testing(transport: transport, recorder: recorder)

        await #expect(throws: MailError.self) {
            _ = try await client.get(.accounts)
        }
        // One send plus three retries.
        #expect(await transport.sendCount == 4)
        #expect(await recorder.delays == [.seconds(2), .seconds(8), .seconds(30)])
    }

    @Test("a PUT does not retry at all")
    func neverRetriesMutations() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(status: 500))
        let recorder = DelayRecorder()
        let client = MailClient.testing(transport: transport, recorder: recorder)

        await #expect(throws: MailError.self) {
            _ = try await client.put(.setFlags(messageId: 1), body: SetFlagsRequest(seen: true))
        }
        #expect(await transport.sendCount == 1)
        #expect(await recorder.delays.isEmpty)
    }

    @Test("a retry that succeeds returns the second answer")
    func recoversAfterOneFailure() async throws {
        let transport = FakeTransport()
        await transport.stubSequence(.any, [.init(status: 503), .json("[]")])
        let client = MailClient.testing(transport: transport)
        let accounts = try await client.get(.accounts)
        #expect(accounts.isEmpty)
        #expect(await transport.sendCount == 2)
    }

    @Test("Retry-After overrides the backoff schedule")
    func honoursRetryAfter() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(status: 429, headers: ["Retry-After": "5"]))
        let recorder = DelayRecorder()
        let client = MailClient.testing(transport: transport, recorder: recorder)

        await #expect(throws: MailError.self) {
            _ = try await client.get(.accounts)
        }
        #expect(await recorder.delays == [.seconds(5), .seconds(5), .seconds(5)])
    }

    @Test("a 403 is never retried: it will answer the same way forever")
    func doesNotRetryClientErrors() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(status: 403, body: Data("[]".utf8)))
        let client = MailClient.testing(transport: transport)
        await #expect(throws: MailError.self) {
            _ = try await client.get(.accounts)
        }
        #expect(await transport.sendCount == 1)
    }

    @Test("a transport failure is retried, then surfaces as .transport")
    func retriesTransportFailures() async throws {
        let transport = FakeTransport()
        // A generous failure count reads as "never succeeds within this test" without
        // depending on the exact number of attempts `RetryPolicy` allows.
        await transport.fail(.any, times: 10, then: .json("[]"))
        let client = MailClient.testing(transport: transport)
        do {
            _ = try await client.get(.accounts)
            Issue.record("expected a throw")
        } catch MailError.transport {
            #expect(await transport.sendCount == 4)
        }
    }

    @Test("a 202 surfaces as syncInProgress without being retried")
    func doesNotRetrySyncInProgress() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(status: 202))
        let client = MailClient.testing(transport: transport)
        do {
            _ = try await client.post(.sync(mailboxId: 5), body: SyncRequest(ids: []))
            Issue.record("expected a throw")
        } catch MailError.syncInProgress {
            // The sync engine decides when to ask again; it knows what it sent.
            #expect(await transport.sendCount == 1)
        }
    }
}

@Suite("Decoding through the client")
struct ClientDecodingTests {
    private func client(fixture: String) async throws -> MailClient {
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(body: try FixtureBytes.data(fixture)))
        return MailClient.testing(transport: transport)
    }

    @Test("a malformed payload names its endpoint instead of crashing")
    func reportsDecodingEndpoint() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json(#"{"not":"an array"}"#))
        let client = MailClient.testing(transport: transport)
        do {
            _ = try await client.get(.accounts)
            Issue.record("expected a throw")
        } catch MailError.decoding(_, let endpoint) {
            #expect(endpoint == "accounts")
        }
    }

    @Test("a truncated payload also names its endpoint")
    func reportsTruncatedPayload() async throws {
        let truncated = try FixtureBytes.data("message-body.json").prefix(400)
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(body: Data(truncated)))
        let client = MailClient.testing(transport: transport)
        do {
            _ = try await client.get(.messageBody(id: 66))
            Issue.record("expected a throw")
        } catch MailError.decoding(_, let endpoint) {
            #expect(endpoint == "messageBody")
        }
    }

    @Test("a mutation answering with nothing at all is still a success")
    func toleratesEmptyBody() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .status(204))
        let client = MailClient.testing(transport: transport)
        _ = try await client.delete(.deleteMessage(id: 1))
        #expect(await transport.sendCount == 1)
    }

    @Test("every JSON fixture replays through the client and decodes")
    func replaysFixtures() async throws {
        let accounts = try await client(fixture: "accounts.json").get(.accounts)
        #expect(!accounts.isEmpty)

        let mailboxes = try await client(fixture: "mailboxes-account.json").get(.mailboxes(accountId: 1))
        #expect(!mailboxes.mailboxes.isEmpty)

        let page = try await client(fixture: "messages-inbox-page1.json").get(.messages(mailboxId: 5))
        #expect(page.count == 95)

        let body = try await client(fixture: "message-body.json").get(.messageBody(id: 66))
        #expect(body.value.id > 0)

        let thread = try await client(fixture: "message-thread.json").get(.messageThread(messageId: 66))
        #expect(!thread.isEmpty)

        let sync = try await client(fixture: "sync-initial.json")
            .post(.sync(mailboxId: 5), body: SyncRequest(ids: [], initialise: true))
        #expect(!sync.newMessages.isEmpty)

        let stats = try await client(fixture: "mailbox-stats.json").get(.mailboxStats(mailboxId: 5))
        #expect(stats.total > 0)

        let capabilities = try await client(fixture: "capabilities.json").get(.capabilities)
        #expect(capabilities.data.theming?.color != nil)

        let preference = try await client(fixture: "preference-sort-order.json")
            .get(.preference(key: "sort-order"))
        #expect(preference.stringValue == nil)

        let trusted = try await client(fixture: "trustedsenders.json").get(.trustedSenders)
        #expect(trusted.data.isEmpty)
    }

    @Test("bytes hands back the response untouched")
    func returnsRawBytes() async throws {
        let html = try FixtureBytes.data("message-html-plain.html")
        let transport = FakeTransport()
        await transport.stub(.any, with: .init(body: html, headers: ["Content-Type": "text/html"]))
        let client = MailClient.testing(transport: transport)
        let (data, response) = try await client.bytes(.messageHTML(id: 66))
        #expect(data == html)
        #expect(response.statusCode == 200)
    }

    @Test("a missing avatar is a notFound, which means draw initials")
    func reportsMissingAvatar() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .status(404))
        let client = MailClient.testing(transport: transport)
        await #expect(throws: MailError.self) {
            _ = try await client.bytes(.avatar(email: "nobody@example.invalid"))
        }
    }
}

/// An actor holding a client, which is the way every caller in this app uses
/// one. It compiles or it does not; that is the assertion.
private actor ClientHolder {
    let client: MailClient

    init(client: MailClient) {
        self.client = client
    }

    func accounts() async throws -> [RawBacked<Account>] {
        try await client.get(.accounts)
    }
}

@Suite("Concurrency")
struct ConcurrencyTests {
    @Test("a client crosses into an actor without a warning")
    func usableFromAnActor() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json("[]"))
        let holder = ClientHolder(client: MailClient.testing(transport: transport))
        #expect(try await holder.accounts().isEmpty)
    }
}
