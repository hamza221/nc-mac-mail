// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NCMailNet

/// `StubURLProtocol`'s state is keyed by request path and shared across the
/// whole process, so these tests run one at a time rather than racing each
/// other over the same paths.
@Suite("LoginFlow", .serialized)
struct LoginFlowTests {
    static let server = URL(string: "https://cloud.example.com")!
    static let startPath = "/index.php/login/v2"
    static let pollPath = "/index.php/login/v2/poll"
    static let accountsPath = "/index.php/apps/mail/api/accounts"

    /// A tiny interval and ceiling: real production values are 2 s and
    /// 5 minutes, which no test should wait out. Definition of done forbids
    /// a test that depends on wall-clock time; injecting the constants is
    /// what keeps that true here.
    func makeFlow() -> LoginFlow {
        LoginFlow(session: .stubbed(), pollInterval: .milliseconds(5), pollCeiling: 0.2)
    }

    static func startJSON() -> String {
        """
        {"login": "\(server.absoluteString)/login-page",
         "poll": {"token": "tok-123", "endpoint": "\(server.absoluteString)\(pollPath)"}}
        """
    }

    static func pollSuccessJSON() -> String {
        """
        {"server": "\(server.absoluteString)", "loginName": "alice", "appPassword": "app-secret"}
        """
    }

    @Test("start returns the browser URL and stores the poll token")
    func startSucceeds() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok(Self.startJSON())], forPath: Self.startPath)

        let flow = makeFlow()
        let loginURL = try await flow.start(server: Self.server)

        #expect(loginURL.absoluteString == "\(Self.server.absoluteString)/login-page")
        if case .awaitingBrowser(let url) = await flow.state {
            #expect(url == loginURL)
        } else {
            Issue.record("expected .awaitingBrowser, got \(await flow.state)")
        }
    }

    @Test("a non-2xx on login/v2 means not-Nextcloud")
    func startRejectsNon2xx() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.status(404)], forPath: Self.startPath)

        let flow = makeFlow()
        await #expect(throws: LoginError.notNextcloud) {
            try await flow.start(server: Self.server)
        }
    }

    @Test("a transport failure on login/v2 means unreachable")
    func startMapsTransportFailure() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.failure(.cannotConnectToHost)], forPath: Self.startPath)

        let flow = makeFlow()
        await #expect(throws: LoginError.unreachable) {
            try await flow.start(server: Self.server)
        }
    }

    @Test("a body that isn't login/v2's shape means not-Nextcloud")
    func startRejectsUnexpectedShape() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok("{\"unexpected\": true}")], forPath: Self.startPath)

        let flow = makeFlow()
        await #expect(throws: LoginError.notNextcloud) {
            try await flow.start(server: Self.server)
        }
    }

    @Test("polling keeps going through 404s and succeeds once the browser finishes")
    func fullFlowSucceeds() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok(Self.startJSON())], forPath: Self.startPath)
        StubURLProtocol.enqueue([.status(404), .status(404), .ok(Self.pollSuccessJSON())], forPath: Self.pollPath)
        StubURLProtocol.enqueue([.status(200)], forPath: Self.accountsPath)

        let flow = makeFlow()
        _ = try await flow.start(server: Self.server)
        let credentials = try await flow.awaitCompletion()

        #expect(credentials.loginName == "alice")
        #expect(credentials.appPassword == "app-secret")
        #expect(StubURLProtocol.callCount(forPath: Self.pollPath) == 3)
        if case .succeeded(let stored) = await flow.state {
            #expect(stored == credentials)
        } else {
            Issue.record("expected .succeeded, got \(await flow.state)")
        }
    }

    @Test("a poll success with no Mail app is reported distinctly")
    func mailAppMissingIsDistinguished() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok(Self.startJSON())], forPath: Self.startPath)
        StubURLProtocol.enqueue([.ok(Self.pollSuccessJSON())], forPath: Self.pollPath)
        StubURLProtocol.enqueue([.status(404)], forPath: Self.accountsPath)

        let flow = makeFlow()
        _ = try await flow.start(server: Self.server)
        await #expect(throws: LoginError.mailAppMissing) {
            try await flow.awaitCompletion()
        }
    }

    @Test("giving up after the ceiling is a distinct, retryable timeout")
    func timesOutAfterCeiling() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok(Self.startJSON())], forPath: Self.startPath)
        StubURLProtocol.enqueue([.status(404)], forPath: Self.pollPath)

        let flow = makeFlow()
        _ = try await flow.start(server: Self.server)
        await #expect(throws: LoginError.timedOut) {
            try await flow.awaitCompletion()
        }
    }

    @Test("cancelling before the poll begins stops it before any request is sent")
    func cancelStopsThePoll() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue([.ok(Self.startJSON())], forPath: Self.startPath)
        // No poll stub at all: if `cancel()` did not take effect, the very
        // first poll would 500 from `StubURLProtocol`'s empty-queue default
        // and the test would fail for a different reason than the one it
        // means to check.

        let flow = makeFlow()
        _ = try await flow.start(server: Self.server)
        await flow.cancel()

        await #expect(throws: LoginError.cancelled) {
            try await flow.awaitCompletion()
        }
        #expect(await flow.state == .idle)
        #expect(StubURLProtocol.callCount(forPath: Self.pollPath) == 0)
    }
}
