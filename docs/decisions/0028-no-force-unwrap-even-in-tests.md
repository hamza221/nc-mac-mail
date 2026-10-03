<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0028: No force unwrap anywhere, including tests — `#require` instead

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-14, on a contradiction between `definition-of-done.md` and `.swiftlint.yml`

## Context

[definition-of-done.md](../delivery/definition-of-done.md) said "No force unwrap outside
tests, except where a comment proves the invariant" — permitting one in a test with no
comment required. WS-00's `.swiftlint.yml` disagrees: `force_unwrapping` is `severity: error`
with no path exemption for `Tests/`, and the file's own header says these rules exist to
make an invariant "a build failure rather than a review miss."

The gap is not theoretical. WS-02 hit it and deleted its force unwrap rather than resolve the
contradiction. `FakeTransportTests.swift` (WS-14) hit it a second time, in a private helper
that built a `URLRequest` from a string it controlled:

```swift
var request = URLRequest(url: URL(string: "https://cloud.example.com" + path)!)
```

Two agents independently treating the same lint failure as something to route around, rather
than a document to fix, is what this record exists to stop.

## Decision

The stricter side wins: force unwrap is banned everywhere, including tests, and
`definition-of-done.md` is corrected to say so. `.swiftlint.yml` is unchanged — it already
said this.

The reason is not "consistency" for its own sake. In Swift Testing, `try #require(x)` is
strictly better than `x!` at the one thing a force unwrap is for: turning "this should never
be nil" into a checked assertion. `#require` reports which requirement failed and at which
line; a force unwrap gives a crash and a stack trace pointing at the unwrap, not at the
assumption that was wrong. Every use this ADR fixes was a plain `x!` with no comment proving
an invariant — exactly the case `definition-of-done.md`'s old exception was written for, and
exactly the case where `#require` was already the better tool.

```swift
var request = URLRequest(url: try #require(URL(string: "https://cloud.example.com" + path)))
```

The helper this appears in becomes `throws`; callers already inside a `throws` test gain a
`try` at the call site, which is the whole cost.

## Consequences

One lint config to satisfy, not two documents in tension. A future agent who hits
`force_unwrapping` in a test has one answer — use `#require` — instead of a choice between
"the config is wrong" and "the doc is wrong" with no record of which one a reviewer will
actually enforce.

The narrow case this forecloses: a force unwrap on a literal that cannot fail (`URL(string:
"https://example.com")!`), where a human reviewer would wave it through. `#require`'s only
cost there is one word and a `throws` on the enclosing function, which every `@Test` function
already carries by convention in this codebase.

## Alternatives considered

**Add a `Tests/` path exemption to `.swiftlint.yml`.** Rejected: it would need WS-00 to touch
a file this workstream does not own, for a change that makes the tests *less* informative on
failure, not more convenient — `#require` costs one word over a force unwrap and buys a
useful failure message every time.

**Leave the contradiction and let each workstream choose.** Rejected: it already produced two
independent, silent workarounds (WS-02, WS-14) instead of one fix. A third would be the same
mistake made a third time.

## Revisit when

Never, unless Swift Testing changes what `#require` reports on failure such that a force
unwrap would report more.
