// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

import NCMailNet

/// Reads the recorded fixtures off disk.
///
/// Not `Bundle.module`: `NCMailTestSupport` depends on `NCMailNet`, so
/// `NCMailNet` cannot depend back on it without a package cycle. ADR-0022.
enum Fixture {
    static let directory: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "Packages/NCMailTestSupport/Sources/NCMailTestSupport/Resources/Fixtures")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }
}

/// A transport that answers from a script instead of the network.
///
/// The interim version of what WS-14 will publish from `NCMailTestSupport`.
/// It records every request so a retry test can count sends rather than wait
/// for them.
actor FakeTransport: MailTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data("{}".utf8), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    private var replies: [Reply]
    private var thrown: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) {
        self.replies = replies
    }

    init(alwaysThrowing error: any Error) {
        replies = []
        thrown = error
    }

    /// The same reply for every send, however many there are.
    init(repeating reply: Reply) {
        replies = [reply]
        repeats = true
    }

    private var repeats = false

    var sendCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let thrown { throw MailError.transport(thrown) }
        let reply: Reply
        if repeats {
            // swift-format-ignore: NeverForceUnwrap
            reply = replies[0]
        } else if replies.isEmpty {
            throw MailError.transport(URLError(.unknown))
        } else {
            reply = replies.removeFirst()
        }
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
            )
        else {
            throw MailError.transport(URLError(.badServerResponse))
        }
        return (reply.body, response)
    }
}

extension MailClient {
    /// A client wired to a fake transport, with a retry policy that records the
    /// waits instead of taking them. No test in this workstream sleeps.
    static func testing(
        transport: any MailTransport,
        delays: [Duration] = RetryPolicy.standard.delays,
        recorder: DelayRecorder = DelayRecorder()
    ) -> MailClient {
        MailClient(
            server: URL(string: "https://cloud.example.com")!,
            credentials: BasicCredentials(loginName: "alice", appPassword: "secret"),
            transport: transport,
            retryPolicy: RetryPolicy(
                delays: delays,
                // Identity jitter: the schedule is what the test asserts on.
                jitter: { $0 },
                sleep: { await recorder.record($0) }
            ),
            clientVersion: "test"
        )
    }
}

/// Collects the delays a retry would have slept for.
actor DelayRecorder {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}
