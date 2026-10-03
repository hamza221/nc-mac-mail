// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A canned HTTP outcome for one path, used to drive `LoginFlow` in tests
/// with no real socket. `URLProtocol` predates Swift concurrency and its
/// overrides are called by `URLSession` on threads of its own choosing, so
/// the shared state below is a plain lock rather than an actor: an actor
/// would need every override to `await` it, which `URLProtocol`'s
/// synchronous, non-`async` methods cannot do.
struct StubResponse: Sendable {
    enum Outcome: Sendable {
        case http(status: Int, json: String)
        case transportFailure(URLError.Code)
    }

    let outcome: Outcome

    static func ok(_ json: String) -> StubResponse { StubResponse(outcome: .http(status: 200, json: json)) }
    static func status(_ code: Int) -> StubResponse { StubResponse(outcome: .http(status: code, json: "{}")) }
    static func failure(_ code: URLError.Code) -> StubResponse { StubResponse(outcome: .transportFailure(code)) }
}

final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuesByPath: [String: [StubResponse]] = [:]
    nonisolated(unsafe) private static var callCountsByPath: [String: Int] = [:]

    /// Clears every stub. Call at the start of each test — `URLProtocol`
    /// classes are process-wide, not per-session.
    static func reset() {
        lock.withLock {
            queuesByPath = [:]
            callCountsByPath = [:]
        }
    }

    /// Responses for one request path, consumed in order. Once exhausted,
    /// the last one repeats — which is what lets a poll loop test say
    /// "404 a couple of times, then 200" without enumerating every attempt.
    static func enqueue(_ responses: [StubResponse], forPath path: String) {
        lock.withLock { queuesByPath[path] = responses }
    }

    static func callCount(forPath path: String) -> Int {
        lock.withLock { callCountsByPath[path, default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let response = Self.lock.withLock { () -> StubResponse in
            let count = Self.callCountsByPath[path, default: 0]
            Self.callCountsByPath[path] = count + 1
            guard let queue = Self.queuesByPath[path], !queue.isEmpty else {
                return .status(500)
            }
            let index = min(count, queue.count - 1)
            return queue[index]
        }

        switch response.outcome {
        case .http(let status, let json):
            guard let url = request.url,
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .transportFailure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// A session that answers only through `StubURLProtocol`, with the same
    /// cookie-free configuration `LoginFlow.makeSession()` uses in
    /// production — a stray cookie is exactly the kind of bug this test
    /// double should be able to catch.
    static func stubbed() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}
