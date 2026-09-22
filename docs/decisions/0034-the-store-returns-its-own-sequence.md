<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0034: `NCMailStore` returns its own `AsyncSequence`, and no GRDB type crosses its boundary

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** the wave-2 boundary fix, closing the leak [ADR-0029](0029-app-test-target-borrows-its-modules-from-the-host.md) diagnosed

## Context

`MailStore` had `public import GRDB`, five observations returning GRDB's
`AsyncValueObservation`, `read`/`write` taking GRDB's `Database`, and a `MailStoreError`
case carrying a `DatabaseError`. So `NextcloudMail/App/AppSession.swift` and
`NextcloudMail/Theme/ThemeCache.swift` depended on GRDB's symbols while the app target
names GRDB nowhere.

Two reasons that had to close.

[overview.md](../architecture/overview.md#modules) gives `NCMailStore` sole ownership of
the GRDB stack, and [ADR-0013](0013-module-layout.md) spent a package boundary on making
that rule enforceable rather than merely intended. A public signature in GRDB's vocabulary
is that rule leaking: it is what let `NCMailSync` write `store.write { database in … }`
with no `import GRDB` anywhere in the package.

And it was a live build hazard, not a tidiness argument. Xcode links a package product
statically while exactly one target uses it. Add a second — a test bundle, a helper tool,
anything — and the same products are rebuilt as dynamic frameworks;
`NCMailStore_…_PackageProduct.framework` does not re-export GRDB, and **the app itself**
fails to link:

```
Undefined symbol: GRDB.AsyncValueObservation.makeAsyncIterator() -> GRDB.AsyncValueObservation<A>.Iterator
Undefined symbol: nominal type descriptor for GRDB.AsyncValueObservation
```

ADR-0029 worked around it by giving `NextcloudMailTests` exactly one package product and
`SWIFT_INCLUDE_PATHS`/`BUNDLE_LOADER` for the rest, and named this as the real fix.

## Decision

No GRDB type appears in any public signature of `NCMailStore`.

**`StoreObservation<Element>`** replaces `AsyncValueObservation` on `observeAccounts`,
`observeMailboxes`, `observeMessages`, `observeThread` and `observeMetaValue`. It is a
`Sendable` `AsyncSequence` whose only stored property — and whose iterator's only stored
property — is a standard-library type, so a client lays it out without linking GRDB.

The semantics are GRDB's because the implementation is GRDB's. `AsyncValueObservation` is
itself an `AsyncThrowingStream` fed by `ValueObservation.start(in:scheduling:…)`, and
`StoreObservation` starts the same observation with the same `.mainActor` scheduler into
its own stream:

- Values arrive on the main actor, which `ObservationTests.valuesAreDeliveredOnTheMainActor`
  asserts.
- The observation lives exactly as long as the iteration. The stream's `onTermination`
  cancels it, and the iterator owns the stream, so dropping the iterator — which is what
  cancelling or replacing the `Task` around a `for await` does — stops the observation.
  `ObservationTests.droppingTheIteratorStopsTheObservation` waits on that termination
  rather than on a clock.
- The sequence is lazy and multi-pass: nothing starts until something iterates, and two
  iterations are two independent observations.

**`read` and `write` become internal.** They hand out GRDB's `Database`, which is the other
half of the leak. The one caller outside the package was `MirrorCoordinator` stamping
`mailbox.lastPrimedAt` in raw SQL; it uses `MailStore.setLastPrimedAt(_:mailboxId:)` now,
which is the DAO WS-04's library feedback asked for.

**`MailStoreError.unreadable` carries a SQLite result code and message** rather than a
`DatabaseError`. The app catches this case, and a public enum payload is as much a link
dependency as a return type.

Records keep their GRDB conformances. `AccountRecord` and its siblings are what the store
fetches, Swift has no way to make a conformance to a public protocol less visible than the
type, and the boundary that matters is the one a caller can reach through a signature. A
client that never uses the conformance never materialises a GRDB symbol — which is exactly
what the verification below shows.

ADR-0029's workaround comes out. `NextcloudMailTests` declares `NCMailCore`, `NCMailNet`,
`NCMailStore`, `NextcloudUI` and `NCMailFixtures` the ordinary way, and
`SWIFT_INCLUDE_PATHS` is deleted from both of its configurations. `BUNDLE_LOADER` and
`TEST_HOST` stay, because the bundle is still app-hosted and still `@testable import`s the
app.

## Consequences

- The link hazard is not merely avoided, it is gone, and the proof is that the condition
  that used to break it is now the condition the build runs under. With the test target
  declaring the products, Xcode builds them as dynamic frameworks —
  `PackageFrameworks/NCMailStore_…_PackageProduct.framework`,
  `GRDB_…_PackageProduct.framework` — and a cold `xcodebuild test` from a deleted
  DerivedData links the app and runs the 20 app tests.
- A new app-side test file needs no `project.pbxproj` edit, and a workstream that wants
  `NCMailTestSupport` in the app's test bundle can now have it.
- `NCMailSync` can no longer reach the database except through a method on `MailStore`.
  That is the point, and it is also a standing cost: the next thing that wants a query the
  store does not have needs a DAO rather than a closure. `setLastPrimedAt` is the first.
- Three test files in other packages used `store.read`/`store.write` from outside and were
  rewritten against public APIs. `NCMailStoreTests` was unaffected — it already used
  `@testable`, which is how the escape hatch stays available where it belongs.
- `public import GRDB` remains in `Records/**` and `Projections/**`, so GRDB's names are
  still visible to a module that imports `NCMailStore`. Nothing can be done about that
  while the records conform to `FetchableRecord`, and it is a weaker problem than the one
  this closes: visibility of a name, not a symbol in someone else's link line.

## Alternatives considered

**Give the app target an explicit GRDB dependency.** ADR-0029 considered it, and it is
still the wrong shape: it pins GRDB's version in two places and makes `ValueObservation`
importable from view code, which is the thing the package boundary exists to prevent.

**Wrap `AsyncValueObservation` in a struct and store it.** The obvious wrapper, and it
reintroduces the bug: generic metadata for a struct whose field is a GRDB type needs that
type's descriptor, which is the second undefined symbol in the error above. The wrapper has
to store standard-library types only, which is what forced the `AsyncThrowingStream` shape.

**Bridge with a pump `Task` instead of starting the observation directly.** Simpler to
write — `for try await value in grdbSequence { continuation.yield(value) }` — and it loses
the main-actor guarantee, because the value is then produced by whatever executor the pump
runs on. `concurrency.md` says observations are delivered on the main actor; a wrapper that
quietly stopped doing that would be worse than the leak.

**Leave `read`/`write` public as a documented escape hatch.** Much smaller diff. Rejected
because it leaves a public signature in GRDB's vocabulary, which is the thing the app
target must not have, and because "documented escape hatch" is how the leak got there.

## Revisit when

GRDB's records stop needing a public conformance — a macro, or a generated shadow type —
at which point `public import GRDB` can leave the package entirely. Or when a second
consumer wants an observation the store does not expose, and `StoreObservation` has to grow
beyond "the same thing GRDB does".
