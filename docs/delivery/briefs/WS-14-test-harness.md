# WS-14 — Fake transport, fixtures, recorder, CI gates

**Starts in wave 1 after WS-02, lands continuously. Size: M.**

## Goal

Make the hard things testable: a transport that lies on command, fixtures recorded from a
real server, and CI that catches what a human reviewer will not.

## Before you start

- [../testing-strategy.md](../testing-strategy.md) — **all of it**
- [../../architecture/networking.md](../../architecture/networking.md) — the transport seam
- [../../architecture/sync-engine.md](../../architecture/sync-engine.md) — the cases that need faking

## You own

`Packages/NCMailTestSupport/**` (a fifth, test-only package: SwiftPM test targets cannot
reference files outside their own package, so the fixtures live here and the other
packages' test targets depend on it), `Scripts/record-fixtures.sh`, the CI test jobs

## Build

**`FakeTransport`** — a `MailTransport` that replays fixtures and misbehaves on demand:

```swift
public actor FakeTransport: MailTransport {
    public func stub(_ match: RequestMatcher, with response: StubResponse)
    public func stubSequence(_ match: RequestMatcher, _ responses: [StubResponse])  // 428 then 200
    public func stall(_ match: RequestMatcher) async -> CheckedContinuation<Void, Never>
    public func fail(_ match: RequestMatcher, times: Int, then: StubResponse)
    public var requests: [URLRequest] { get }     // for asserting counts and concurrency
}
```

It must make all of these easy, because every one is a real failure mode: 428 then 200; 202
three times then 200; a 429 with `Retry-After`; a request that never returns (cancellation);
a page sequence for pagination; a `/body` that 404s; concurrency assertions ("never more
than two in flight").

**No `sleep` anywhere.** Time is injected; stalls are continuations the test resumes.

**`Scripts/record-fixtures.sh`** — records real responses against a live instance and
scrubs them: addresses become `user1@example.com`, tokens, hmacs and URL credentials are
replaced, subjects and preview text are kept (they are what makes decoding tests real)
unless `--scrub-content` is passed. Scrubbing is part of the recorder, not a manual step
someone forgets.

Fixtures are resources of this package —
`Packages/NCMailTestSupport/Sources/NCMailTestSupport/Fixtures/` with `.process`
in the manifest — loaded through `Bundle.module`, so every package's tests reach them
without a path outside their own directory.

The fixture set is listed in [../testing-strategy.md](../testing-strategy.md). Record error
responses too — a 202 sync, a 428, a 400 not-cached, a 404 avatar. Error fixtures are the
ones nobody has when they are needed.

**Seeding.** `MailStoreFixtures.seed(messages: 50_000)` for the performance tests WS-03,
WS-08 and WS-11 all need, generating plausible threads, dates, flags and bodies rather than
identical rows — identical rows make every index look brilliant.

**CI gates** per the testing strategy: package build and test with warnings as errors, lint,
`xcodebuild build`, Thread Sanitizer on package tests, and a nightly synthetic 50,000-message
backfill asserting time and peak memory.

## Acceptance

- Every wave-2 workstream can write its failure-path tests without touching `URLSession`.
- Recorded fixtures decode against WS-02's models and are committed scrubbed — verify by
  grepping the fixture directory for the real domain and finding nothing.
- The seeder produces 50,000 messages in under five seconds.
- The nightly job fails when a deliberate 200 ms delay is added to a query.
- No test anywhere in the repository touches a real server.

## Out of scope

Writing other workstreams' tests. You provide the tools; they use them. Snapshot tests for
app views — explicitly not wanted in v1.

## Report

Additionally: what the fake transport could not express and had to be worked around, since
that is a design smell in the seam and worth fixing early.
