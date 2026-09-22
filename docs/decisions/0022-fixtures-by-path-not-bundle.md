<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0022: Tests read fixtures by path, because `Bundle.module` would need a package cycle

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-02, on a SwiftPM constraint discovered while writing the first decoding test

## Context

[testing-strategy.md](../delivery/testing-strategy.md) says every package's tests load
fixtures from `NCMailTestSupport` through `Bundle.module`. `NCMailTestSupport` exists
because a SwiftPM test target cannot read resources outside its own package.

Its manifest, written by WS-00, declares:

```swift
dependencies: [.package(path: "../NCMailCore"), .package(path: "../NCMailNet"),
               .package(path: "../NCMailStore")]
```

So `NCMailCoreTests` cannot depend on `NCMailTestSupport`: `NCMailCore` →
`NCMailTestSupport` → `NCMailCore` is a package cycle and SwiftPM rejects it. The same
applies to `NCMailNetTests` and `NCMailStoreTests` — which is to say, to every test that the
strategy document was written for. Only `NCMailTestSupportTests` can use `Bundle.module`,
and that target belongs to WS-14.

WS-02 owns neither the manifest nor `NCMailTestSupport`, and WS-01 and WS-03 were editing
the same packages at the time.

## Decision

Each test target resolves the fixture directory from `#filePath`, which SwiftPM fixes at
compile time, and reads the files with `Data(contentsOf:)`. It is a fifteen-line `Fixture`
enum, duplicated in `NCMailCoreTests` and `NCMailNetTests`.

The fixtures stay where they are. Nothing about the recorder, the committed files or the
`.copy` resource rule changes.

## Consequences

Tests decode the same bytes the recorder wrote, today, without waiting on a manifest change
owned by another workstream.

Fifteen lines are duplicated in two test targets, and a third copy will appear in
`NCMailStoreTests`. That is the cost, and it is the reason this record exists rather than a
comment.

The path is relative to the source file, so moving a test file up or down a directory breaks
it — loudly, at the first read, not subtly.

`Bundle.module` remains the better answer. It needs one of two changes that WS-00 or WS-14
owns: either `NCMailTestSupport` drops its three dependencies and becomes a leaf that only
vends bytes, or the fixtures move into a leaf `NCMailFixtures` target inside it that the
helpers depend on rather than the other way round. WS-02's report asks for the first.

## Alternatives considered

**Edit `Packages/NCMailTestSupport/Package.swift` to break the cycle.** It is WS-00's file
and WS-14's package, and two agents editing one manifest while three packages are in flight
is exactly the conflict the ownership table exists to prevent.

**Copy the fixtures into each test target's own resources.** Four copies of 400 KB, and four
chances for one of them to be stale. A fixture that disagrees with the recorder is worse
than no fixture.

**Put every decoding test in `NCMailTestSupportTests`.** It would work, and it would put
`NCMailCore`'s tests in someone else's package, where a failure points at the wrong
workstream.

## Revisit when

`NCMailTestSupport` becomes a leaf, or grows a leaf fixture target. At that point the
`Fixture` helpers are deleted and the tests import it, which is a mechanical change.
