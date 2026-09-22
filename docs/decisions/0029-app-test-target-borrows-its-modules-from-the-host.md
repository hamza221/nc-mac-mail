<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0029: The app's test target borrows its modules from the host app

**Status:** Accepted; the workaround it describes was removed by
[ADR-0034](0034-the-store-returns-its-own-sequence.md) on 2026-09-22
**Date:** 2026-09-22
**Decided by:** WS-00 follow-up, after `xcodebuild test` broke the app's own link

## What changed

This record's diagnosis was right and its workaround is gone. `NCMailStore` no longer
returns `AsyncValueObservation` or any other GRDB type from a public signature
([ADR-0034](0034-the-store-returns-its-own-sequence.md)), so the app has no GRDB symbol to
resolve and the linkage rule below no longer has anything to break.

`NextcloudMailTests` now declares `NCMailCore`, `NCMailNet`, `NCMailStore`, `NextcloudUI`
and `NCMailFixtures` as ordinary package products, and `SWIFT_INCLUDE_PATHS` is deleted
from both of its build configurations. `BUNDLE_LOADER` and `TEST_HOST` stay: the bundle is
app-hosted because it `@testable import`s the app, which is a separate reason from the one
below. Xcode now does build the products as dynamic frameworks — a cold `xcodebuild test`
produces `PackageFrameworks/NCMailStore_…_PackageProduct.framework` and
`GRDB_…_PackageProduct.framework` — and the app links and the tests run, which is the
condition that used to fail.

The rest of this record stands as the account of why it failed and how it was found.

## Context

WS-00 shipped one native target. WS-13 was the first workstream with app-side logic worth
testing, found there was nowhere to put a test, and said so rather than working around it.
Six app-side workstreams are queued behind it, so the gap had to close before any of them
inherits a standing excuse.

Adding the target is three lines of `project.pbxproj` and a synchronised group, exactly as
[ADR-0017](0017-file-system-synchronized-group.md) does for the app. Wiring it up the way
Xcode's own template does is where it goes wrong.

`NextcloudMailTests` needs `NCMailStore` (for `MailStore` and `MirrorProgress`), `NCMailNet`
(for `MailClient`) and `NextcloudUI` (for `NCTheme`). The obvious move is to add those three
products to the test target, which is what Xcode's UI does. Doing it makes the **app** stop
linking:

```
Undefined symbol: GRDB.AsyncValueObservation.makeAsyncIterator() -> GRDB.AsyncValueObservation<A>.Iterator
Undefined symbol: nominal type descriptor for GRDB.AsyncValueObservation
Ld .../NextcloudMail.app/Contents/MacOS/NextcloudMail normal
** TEST FAILED **
```

The cause is Xcode's linkage rule for package products, not anything in our code. With one
client, Xcode links each package product **statically** — a cold build of `main` produces
`GRDB.o`, `NCMailStore.o` and no `PackageFrameworks` directory at all, so GRDB's object code
lands inside the app binary. Add a second client and Xcode rebuilds the same products as
dynamic frameworks. The app then links `NCMailStore_…_PackageProduct.framework`, which does
not re-export GRDB, and `NextcloudMail/App/AppSession.swift` iterating
`store.observeMetaValue(forKey:)` has nowhere to resolve `AsyncValueObservation` from.

That last sentence is the real finding underneath the link error:
`MailStore.observeMetaValue` returns a GRDB type through a `public import GRDB`, so the app
target already depends on GRDB's symbols without naming GRDB anywhere. Static linking has
been hiding it since WS-00. Fixing that means changing `NCMailStore`'s signature or
`AppSession`, neither of which belongs to this change.

## Decision

`NextcloudMailTests` declares exactly one package product, `NCMailFixtures`, and takes every
other module from the host app:

- `SWIFT_INCLUDE_PATHS = "$(BUILT_PRODUCTS_DIR)"` so `import NCMailStore`, `import NCMailNet`
  and `import NextcloudUI` find the `.swiftmodule` files the app target has already built
  into that directory.
- `BUNDLE_LOADER`/`TEST_HOST` pointing at the app, so the symbols behind those imports
  resolve against the host binary at load time. The app statically contains all of them.
- No entry in the test bundle's Link Binary phase for anything the app already carries.

Every package product therefore still has exactly one client, Xcode still links them
statically, and the app's link line is byte-for-byte what it was before the test target
existed.

`NCMailFixtures` is the one exception because the app does not contain it and nothing else
can supply the recorded bytes. It has no dependencies of its own
([ADR-0026](0026-fixtures-through-a-dependency-free-target.md)), so linking it adds one more
single-client product rather than a second client for an existing one.

The fuller `NCMailTestSupport` product stays out: it depends on `NCMailCore`, `NCMailNet` and
`NCMailStore`, which is precisely the second client that breaks the app. The two app-side
tests that need a transport use a twenty-line `ReplayTransport` in the test target instead of
`FakeTransport`.

## Consequences

- `make test-app` runs 20 tests against WS-13's logic, and `make build-app` produces the same
  binary it did before. Both are verified cold, from a deleted DerivedData.
- A new test file needs no `project.pbxproj` edit, the same property ADR-0017 bought for the
  app.
- A later workstream that wants a package product the app does **not** link — a second
  `NCMailTestSupport`-shaped dependency — will hit the same link failure. The fix at that
  point is to give the app target an explicit GRDB dependency, or to stop returning
  `AsyncValueObservation` from `NCMailStore`'s public interface. This record exists so that
  debugging session is five minutes rather than an afternoon. *(The second fix is the one
  that was taken — ADR-0034.)*
- `SWIFT_INCLUDE_PATHS` is an unusual setting to find in a test target and looks like
  something a generator left behind. It is load-bearing; removing it breaks the build with a
  "no such module" that does not explain itself. *(No longer present.)*
- The test bundle is app-hosted, so `xcodebuild test` launches `NextcloudMail.app`.
  `NextcloudMailApp.init` opens the real mirror in the sandbox container and reads the
  Keychain. That is a slower and more stateful test run than a package's, which is a reason
  to keep app-side tests for app-side logic and leave everything else in the packages.

## Alternatives considered

**Add GRDB to the app target.** Honest, in that the app really does use a GRDB type, and it
makes the link work whichever way Xcode chooses to link. Rejected here because it puts a
second pin on GRDB's version next to `NCMailStore`'s and makes GRDB importable from view
code, which [ADR-0013](0013-module-layout.md) spent a package boundary preventing. It is the
right fix for the underlying leak and the wrong fix for "the tests do not build".

**Link `NCMailTestSupport` and accept the dynamic frameworks.** Two copies of `MailStore`'s
type metadata in one process, in the app binary and in the test bundle, with casts between
them as the failure mode. Not worth `FakeTransport`.

**`ENABLE_DEBUG_DYLIB = NO`.** Tried first, on the theory that the debug dylib was what
changed. It moved the same undefined symbols from `NextcloudMail.debug.dylib` to
`NextcloudMail`, which is how the static-versus-dynamic cause was found. Reverted.

**XcodeGen.** Would have made the target trivial to declare and would have chosen the same
linkage, because the linkage is Xcode's rule and not the generator's. It also reverses
[ADR-0001](0001-xcode-project-in-git.md), which is not a call this change gets to make alone.

## Revisit when

Already revisited. `NCMailStore` stopped returning GRDB types from its public interface,
`NextcloudMailTests` declares its package products the ordinary way, and
`SWIFT_INCLUDE_PATHS` came out. See [ADR-0034](0034-the-store-returns-its-own-sequence.md).
