// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
public import NCMailNet

/// A `MailTransport` that never touches the network.
///
/// Every wave-2 workstream (WS-04 through WS-06) writes its failure-path tests against this
/// type instead of `URLSession` — see `docs/delivery/testing-strategy.md` and
/// `docs/architecture/networking.md#transport-seam`. An actor, because requests can arrive
/// concurrently (the concurrency budget in `networking.md` runs several at once) and the
/// stub bookkeeping — which response is next, how many failures remain, who is stalled — is
/// exactly the kind of state `docs/architecture/concurrency.md` says an actor should own
/// rather than a lock.
///
/// No `sleep`, no wall clock, anywhere in this type. A `fail` still "retries" purely by
/// counting calls; a `stall` suspends on a continuation the test resumes, never on a timer.
public actor FakeTransport: MailTransport {
    private enum Behavior {
        case fixed(StubResponse)
        /// Consumed front to back; once one element is left, it repeats — a sequence that
        /// "ran out" is almost always a test that forgot to plan for a retry, not an
        /// intentional assertion, so repeating the last one is the fewer-surprises default.
        case sequence([StubResponse])
        case failing(remaining: Int, then: StubResponse)
    }

    private struct StallWaiter {
        let matcher: RequestMatcher
        let continuation: CheckedContinuation<CheckedContinuation<Void, Never>, Never>
    }

    private var log: [URLRequest] = []
    private var behaviors: [(matcher: RequestMatcher, behavior: Behavior)] = []
    private var stallWaiters: [StallWaiter] = []
    private var activeStalls: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var inFlight = 0
    private var peakInFlight = 0

    public init() {}

    /// Every request sent so far, oldest first — for asserting counts, and for reading back
    /// exactly what a caller built (headers, body, method).
    public var requests: [URLRequest] { log }

    /// `requests.count`, spelled out for the common case of asserting a retry count.
    public var sendCount: Int { log.count }

    /// The highest number of `send` calls that were simultaneously awaiting a response.
    /// Compare against the concurrency budget in `networking.md` — "never more than two in
    /// flight" is `#expect(await transport.peakInFlightCount <= 2)`.
    public var peakInFlightCount: Int { peakInFlight }

    // MARK: - Stubbing

    /// The same response every time `match` fires.
    public func stub(_ match: RequestMatcher, with response: StubResponse) {
        behaviors.append((match, .fixed(response)))
    }

    /// One response per matching call, in order; the last one repeats once the list is
    /// exhausted. `stubSequence(.pathSuffix("/sync"), [.status(428), .fixture("sync-initial.json")])`
    /// is "428 then 200" from the brief, spelled out.
    public func stubSequence(_ match: RequestMatcher, _ responses: [StubResponse]) {
        behaviors.append((match, .sequence(responses)))
    }

    /// Throws a transport failure for the next `times` matching calls, then answers `then`.
    /// `times` need not be small: a very large count reads as "never succeeds" without a
    /// separate "always fail" entry point.
    public func fail(_ match: RequestMatcher, times: Int, then: StubResponse) {
        behaviors.append((match, .failing(remaining: times, then: then)))
    }

    /// Suspends the next request matching `match` until the returned handle is resumed —
    /// indefinitely, if the test never resumes it. This is the primitive
    /// `docs/architecture/concurrency.md` means by "the fake transport can stall a request
    /// indefinitely, which is how cancellation is tested": start the request, `await` this
    /// method to get its handle, cancel the enclosing `Task`, and confirm `send` throws
    /// `CancellationError` promptly rather than hanging forever.
    ///
    /// Call this *before* triggering the request it is meant to catch — typically with
    /// `async let`, so the registration exists by the time the request arrives:
    ///
    /// ```swift
    /// async let handle = transport.stall(.pathSuffix("/sync"))
    /// async let result = client.post(.sync(mailboxId: 5), body: ...)
    /// let release = await handle
    /// // ... assert the caller is still waiting, or cancel it ...
    /// release.resume()
    /// _ = try await result
    /// ```
    ///
    /// Resuming the handle and cancelling the awaiting task are alternatives, not steps to
    /// combine: like any `CheckedContinuation`, resuming twice is a crash. Pick one per
    /// stall — resume it to prove the caller continues correctly, or cancel to prove it
    /// unwinds correctly, not both.
    public func stall(_ match: RequestMatcher) async -> CheckedContinuation<Void, Never> {
        await withCheckedContinuation { waiter in
            stallWaiters.append(StallWaiter(matcher: match, continuation: waiter))
        }
    }

    // MARK: - MailTransport

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.append(request)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }

        if let waiterIndex = stallWaiters.firstIndex(where: { $0.matcher.matches(request) }) {
            let waiter = stallWaiters.remove(at: waiterIndex)
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (release: CheckedContinuation<Void, Never>) in
                    activeStalls[id] = release
                    waiter.continuation.resume(returning: release)
                }
            } onCancel: {
                Task { await self.releaseStalled(id) }
            }
            // Resumed either by the test or by `releaseStalled`; either way this stall is
            // over, so forget it before the other path can find and re-resume it.
            activeStalls.removeValue(forKey: id)
            if Task.isCancelled { throw CancellationError() }
        }

        return try response(for: request)
    }

    /// Resumes a stalled `send()` when its task is cancelled rather than released by the
    /// test. Guarded by removal from `activeStalls`: if the test already called
    /// `release.resume()` directly (bypassing the actor, as `CheckedContinuation.resume()`
    /// always can), the entry is gone by the time this runs and there is nothing to do.
    /// That leaves the reverse order — cancel first, then the test also calls `resume()` —
    /// genuinely unguarded; see `stall`'s doc comment.
    private func releaseStalled(_ id: UUID) {
        guard let continuation = activeStalls.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    // MARK: - Resolution

    private func response(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let index = behaviors.firstIndex(where: { $0.matcher.matches(request) }) else {
            throw FakeTransportError.unstubbed(request.url?.absoluteString ?? "(no URL)")
        }
        let matcher = behaviors[index].matcher
        switch behaviors[index].behavior {
        case .fixed(let stub):
            return try httpResponse(stub, for: request)

        case .sequence(let responses):
            // Never empty once stored: `stubSequence` always keeps at least the last entry
            // (see below), and an empty array passed in is treated as "no stub" so a test
            // gets `unstubbed` rather than a silently-ignored registration.
            guard let next = responses.first else {
                throw FakeTransportError.unstubbed(request.url?.absoluteString ?? "(no URL)")
            }
            if responses.count > 1 {
                behaviors[index] = (matcher, .sequence(Array(responses.dropFirst())))
            }
            return try httpResponse(next, for: request)

        case .failing(let remaining, let then):
            if remaining > 0 {
                behaviors[index] = (matcher, .failing(remaining: remaining - 1, then: then))
                throw MailError.transport(URLError(.networkConnectionLost))
            }
            return try httpResponse(then, for: request)
        }
    }

    private func httpResponse(_ stub: StubResponse, for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        else {
            throw FakeTransportError.invalidResponse
        }
        return (stub.body, response)
    }
}

/// What can go wrong with the fake itself, as opposed to what it is faking.
public enum FakeTransportError: Error, CustomStringConvertible, Sendable {
    /// No `stub`, `stubSequence` or `fail` matched this request. Almost always a missing
    /// registration in the test, not a bug in the code under test — the message names the
    /// URL so the fix is obvious without a debugger.
    case unstubbed(String)
    case invalidResponse

    public var description: String {
        switch self {
        case .unstubbed(let url):
            "FakeTransport has no stub for \(url). Register one with stub/stubSequence/fail before sending."
        case .invalidResponse:
            "FakeTransport could not build an HTTPURLResponse for the given status and headers."
        }
    }
}
