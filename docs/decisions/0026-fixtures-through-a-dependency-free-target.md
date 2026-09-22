<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0026: Fixtures through a dependency-free `NCMailFixtures` target, not a `#filePath` walk

**Status:** Accepted — supersedes [ADR-0022](0022-fixtures-by-path-not-bundle.md) for
`NCMailCoreTests` and `NCMailStoreTests`
**Date:** 2026-09-22
**Decided by:** WS-14, closing the gap ADR-0022 left open

## Context

ADR-0022 recorded a SwiftPM constraint: `NCMailTestSupport` depends on `NCMailCore`,
`NCMailNet` and `NCMailStore`, so none of those three packages' test targets can depend back
on it without a package cycle. `Bundle.module`, which
[testing-strategy.md](../delivery/testing-strategy.md) specifies for every package's tests,
was reachable only from `NCMailTestSupportTests`. `NCMailCoreTests` and `NCMailNetTests`
worked around it with a fifteen-line `Fixture` enum that resolves the fixture directory from
`#filePath` and reads bytes with `Data(contentsOf:)`; `NCMailStoreTests` grew a third copy
(`RecordedFixture`) doing the same thing.

ADR-0022 named two ways to close the gap: make `NCMailTestSupport` itself a leaf (drop its
three dependencies), or move the fixtures into a leaf target inside it that the
model-aware helpers depend on rather than the other way round. The first was never
realistic — `NCMailTestSupport` is specified to hold `FakeTransport`, which has to speak
`NCMailNet`'s `MailTransport` protocol, and `MailStoreFixtures`, which has to write through
`NCMailStore`. Dropping those dependencies would just move the problem into whichever
package ends up holding the fake transport.

The second was worth testing rather than assuming, because it looks like it should hit the
same cycle: if `NCMailCore`'s manifest declares a dependency on `NCMailTestSupport` (to reach
the leaf), and `NCMailTestSupport`'s manifest declares a dependency on `NCMailCore` (for the
main target), that is two manifests each listing the other. A throwaway two-package
experiment (`PackageA` with a test target depending on `PackageB`'s zero-dependency `Leaf`
product, `PackageB` with a second target depending back on `PackageA`) built and ran clean
under `swift build` and `swift test`: SwiftPM's cycle check operates on the target-level
build graph, not on the textual list of packages a manifest names. A target with no
dependencies has no edge for the cycle to run through, however many other targets in the
same package point back at the consumer.

## Decision

`NCMailTestSupport`'s manifest now declares two library products from one package:

- **`NCMailFixtures`** — a target with no dependencies at all. It vends the recorded bytes
  (`FixtureBytes.data(_:)`, `FixtureBytes.decode(_:from:)`) through `Bundle.module`, and
  nothing else. `NCMailCoreTests` and `NCMailStoreTests` depend on this product directly.
- **`NCMailTestSupport`** — the target that depends on `NCMailCore`, `NCMailNet` and
  `NCMailStore`, and depends on `NCMailFixtures` for the bytes underneath its model- and
  transport-aware helpers (`FakeTransport`, `MailStoreFixtures`).

`Packages/NCMailCore/Package.swift` and `Packages/NCMailStore/Package.swift` each gained one
dependency — `.package(path: "../NCMailTestSupport")` — used only to reach the
`NCMailFixtures` product from their test targets. `NCMailCoreTests/Fixtures.swift` and
`NCMailStoreTests/TestHelpers.swift`'s `RecordedFixture` now delegate to `FixtureBytes`
instead of walking `#filePath`.

`NCMailNetTests` keeps its ADR-0022 workaround. Fixing it the same way needs a matching edit
to `Packages/NCMailNet/Package.swift`, which is outside what this workstream is authorised to
touch; the fixture *directory* it points at moved (to `NCMailFixtures`'s resources), so its
path was corrected, but the `#filePath` walk itself stays until whoever owns that manifest
makes the same one-line change.

## Consequences

`NCMailCoreTests` and `NCMailStoreTests` load fixtures the way
[testing-strategy.md](../delivery/testing-strategy.md) always said they should: through
`Bundle.module`, resolved by SwiftPM rather than by walking the file system from a source
file's own location. A test file can move without silently breaking fixture loading.

Two copies of the `#filePath` walk are gone; one remains, in `NCMailNetTests`, and is now the
only place in the repository this pattern still lives. It is one manifest line and one
import statement away from going the same way.

`NCMailStore`'s manifest gained a test-only dependency on `NCMailTestSupport`, whose own
manifest depends on `NCMailStore`. This reads as circular and is not: SwiftPM resolves
dependencies per target, and the target `NCMailStoreTests` actually uses
(`NCMailFixtures`) has no dependency on anything, so there is no cycle for the build graph to
detect. Anyone re-deriving this from the manifests alone, without running the build, could
reasonably conclude otherwise — which is the whole reason this record exists instead of a
comment.

## Alternatives considered

**Drop `NCMailTestSupport`'s three dependencies entirely**, as ADR-0022's first option
proposed. Rejected: `FakeTransport` and `MailStoreFixtures` need them, and moving those
types to yet another package only relocates the dependency, it does not remove it.

**A genuinely separate top-level package (`Packages/NCMailFixtures/`)** rather than a second
target inside `NCMailTestSupport`. It would work identically — the cycle check is
target-level either way — but it would need its own `Package.swift`, its own entry in the
Makefile's `PACKAGES` list and the CI matrix, and a second place recording where fixtures
live. A second target in the existing package gets the same isolation for one manifest edit
instead of several files across two workstreams' territory (`Makefile` and `.github/` are
WS-00's).

**Leave `NCMailNetTests`'s workaround as the pattern for all three**, closing the gap by
matching the second copy to the first two rather than the other way round. Rejected: it
would mean permanently declining `Bundle.module`, which is what the SwiftPM constraint
actually can be worked around into, and it would leave three copies of the same fifteen
lines instead of one.

## Revisit when

Whoever owns `Packages/NCMailNet/Package.swift` next touches it: add the
`../NCMailTestSupport` dependency and the `NCMailFixtures` product reference, delete
`NCMailNetTests/TestSupport.swift`'s `Fixture` enum, and this ADR's "Alternatives" section
about the one remaining copy is done.
