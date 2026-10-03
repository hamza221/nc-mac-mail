// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import Testing

@testable import NCMailTestSupport

@Suite("FakeTransport")
struct FakeTransportTests {
    private func request(path: String = "/x", method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: "https://cloud.example.com" + path)))
        request.httpMethod = method
        return request
    }

    @Test("a fixed stub answers every time")
    func fixedStub() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json(#"{"ok":true}"#))
        for _ in 0..<3 {
            let (data, response) = try await transport.send(request())
            #expect(response.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        }
        #expect(await transport.sendCount == 3)
    }

    @Test("stubSequence plays 428 then 200, and repeats the last answer")
    func stubSequence() async throws {
        let transport = FakeTransport()
        await transport.stubSequence(.pathSuffix("/sync"), [.status(428), .json("[]")])
        let first = try await transport.send(request(path: "/mailboxes/5/sync"))
        let second = try await transport.send(request(path: "/mailboxes/5/sync"))
        let third = try await transport.send(request(path: "/mailboxes/5/sync"))
        #expect(first.1.statusCode == 428)
        #expect(second.1.statusCode == 200)
        #expect(third.1.statusCode == 200)
    }

    @Test("fail throws a transport error for the given count, then answers normally")
    func failThenSucceed() async throws {
        let transport = FakeTransport()
        await transport.fail(.any, times: 2, then: .json("[]"))
        var failures = 0
        for _ in 0..<2 {
            do {
                _ = try await transport.send(request())
                Issue.record("expected a transport failure")
            } catch MailError.transport {
                failures += 1
            }
        }
        #expect(failures == 2)
        let (_, response) = try await transport.send(request())
        #expect(response.statusCode == 200)
    }

    @Test("matchers combine with &&")
    func combinedMatcher() async throws {
        let transport = FakeTransport()
        await transport.stub(.method("POST") && .pathSuffix("/sync"), with: .status(202))
        await transport.stub(.method("GET") && .pathSuffix("/sync"), with: .status(200))
        let post = try await transport.send(request(path: "/mailboxes/5/sync", method: "POST"))
        let get = try await transport.send(request(path: "/mailboxes/5/sync", method: "GET"))
        #expect(post.1.statusCode == 202)
        #expect(get.1.statusCode == 200)
    }

    @Test("an unstubbed request throws, naming the URL, rather than crashing or guessing")
    func unstubbedRequest() async throws {
        let transport = FakeTransport()
        await #expect(throws: FakeTransportError.self) {
            _ = try await transport.send(request(path: "/never-stubbed"))
        }
    }

    @Test("stall suspends the request until the test resumes it")
    func stallThenResume() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json(#"{"released":true}"#))

        async let release = transport.stall(.any)
        async let result = transport.send(try request())

        let handle = await release
        // The send is genuinely still suspended: nothing has answered it yet.
        #expect(await transport.sendCount == 1)
        handle.resume()

        let (data, response) = try await result
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"released":true}"#)
    }

    @Test("cancelling a stalled send throws CancellationError promptly, without a timeout")
    func stallThenCancel() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json("{}"))

        async let release = transport.stall(.any)
        let task = Task {
            try await transport.send(try request())
        }
        _ = await release

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation to surface")
        } catch is CancellationError {
            // Exactly what a stalled request cancelling must do: no sleep, no
            // deadline, the fake resumes it the moment the task is cancelled.
        }
    }

    @Test("requests captures every send, in order, with its real headers and body")
    func requestLog() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json("{}"))
        var first = try request(path: "/a")
        first.setValue("v1", forHTTPHeaderField: "X-Test")
        _ = try await transport.send(first)
        _ = try await transport.send(request(path: "/b"))

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/a")
        #expect(requests[0].value(forHTTPHeaderField: "X-Test") == "v1")
        #expect(requests[1].url?.path == "/b")
    }

    @Test("peakInFlightCount reports the highest concurrency actually reached")
    func peakInFlight() async throws {
        let transport = FakeTransport()
        await transport.stub(.any, with: .json("{}"))

        async let a = transport.stall(.pathSuffix("/a"))
        async let b = transport.stall(.pathSuffix("/b"))
        async let sendA = transport.send(try request(path: "/a"))
        async let sendB = transport.send(try request(path: "/b"))

        let releaseA = await a
        let releaseB = await b
        #expect(await transport.peakInFlightCount == 2)
        releaseA.resume()
        releaseB.resume()
        _ = try await (sendA, sendB)
    }
}
