<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0016: Ask for warnings-as-errors at the build command, not in the manifests

**Status:** Accepted. The decision stands; its blocking premise no longer does — see
*What changed* below.
**Date:** 2026-09-21
**Decided by:** WS-00, after `xcodebuild -scheme NextcloudMail build` failed on a clean tree

## What changed, 2026-09-22

`NextcloudUI` dropped `.treatAllWarnings(as: .error)` from its manifest in `1e753cb` and
moved the flag to its own build command, which is the fix this project reported upstream.
Verified against the merged commit: **bare `xcodebuild -scheme NextcloudMail build`
succeeds with no override, and the Xcode GUI builds the project.** Two consequences below
are now historical and marked so.

The decision itself is unaffected. Warnings-as-errors still belongs at the build command
rather than in our manifests, because the collision it avoids is a property of how Xcode
builds any package target, not of one library's manifest. `SUPPRESS_WARNINGS=NO` also
stays in the Makefile and CI, for the second reason recorded below: without it, Xcode
suppresses warnings in our own packages during an app build.

## Context

`NextcloudUI`'s `Package.swift` sets `.treatAllWarnings(as: .error)` on every target, and
[WS-00's brief](../delivery/briefs/WS-00-project-skeleton.md) copied that setting into all
five of ours. It compiles fine under `swift build`. Under Xcode it does not compile at all:

```
error: conflicting options '-warnings-as-errors' and '-suppress-warnings'
error: Conflicting options (in target 'NCMailCore' from project 'NCMailCore')
error: Conflicting options (in target 'NextcloudDesign' from project 'nextcloud-ui-swift')
** BUILD FAILED **
```

Xcode passes `-suppress-warnings` to every package target — its way of keeping a
dependency's warnings out of your issue navigator — and swiftc rejects that flag together
with the `-warnings-as-errors` the manifest asks for. Measured on Xcode 26.6 (17F113),
Swift 6.3.3.

Two things make this worse than a nuisance. The suppression is set by Xcode's package
support, and no build setting in `NextcloudMail.xcodeproj` clears it: `SUPPRESS_WARNINGS =
NO` at project level has no effect, because the package targets live in their own
synthesised projects. Only a command-line override reaches them. And one of the failing
targets is `NextcloudDesign`, inside a dependency we do not control.

## Decision

The manifests state the language mode and the upcoming features. They do not ask for
warnings-as-errors. The build command does:

- `swift build -Xswiftc -warnings-as-errors` and the same for `swift test`, in the Makefile
  and in CI. SwiftPM applies `-Xswiftc` to the root package's own targets and not to its
  dependencies, which is the same scope `.treatAllWarnings(as: .error)` had. Verified: GRDB
  still compiles with `-suppress-warnings` and its two Sendable warnings are still its own.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in the app target, where no suppression applies.
- `SUPPRESS_WARNINGS=NO` on every `xcodebuild` invocation in the Makefile and CI. This one
  is for `NextcloudUI`, not for us, and it is the reason `xcodebuild -scheme NextcloudMail
  build` on its own still fails. `make build-app` is the supported command.

## Consequences

- Every package is built once as the root package in CI, so every package's warnings are
  errors there. Nothing is checked less than it was.
- A warning introduced in package code does not fail an Xcode build of the app. CI catches
  it, and `make build` catches it locally. The feedback is minutes later than it was.
- ~~The project **cannot be built from the Xcode GUI**~~ — **no longer true as of
  `NextcloudUI` 1e753cb.** It was true when this was written: the GUI had nowhere to put
  the override and Cmd-B failed with the error above. Filed in
  [../feedback/library-feedback.md](../feedback/library-feedback.md) as a blocker, fixed
  upstream and merged. It is the single most valuable thing WS-00 found for the library,
  and it is the first piece of feedback from this project to complete the round trip.
- `SUPPRESS_WARNINGS=NO` also un-suppresses GRDB, so an app build prints two
  "type 'Any' does not conform to the 'Sendable' protocol" warnings from
  `GRDB/Record/EncodableRecord.swift` and `FetchableRecord.swift`. Kept visible on purpose:
  the alternative hides our own package warnings from anyone building the app.

## Alternatives considered

**Keep `.treatAllWarnings(as: .error)` and pass `SUPPRESS_WARNINGS=NO` everywhere.** Works
for `make` and CI, identical on the GUI (broken either way, by the library). Rejected
because it stays broken after the library is fixed, and the next person debugging it has to
rediscover all of this.

**Detect Xcode in the manifest and set the flag conditionally.** Manifest evaluation under
`xcodebuild` inherits a plain login environment with no `XCODE_*`, no `DEVELOPER_DIR` and no
`SDKROOT` — checked by making a manifest fail and reading back its environment. There is
nothing to branch on.

**Drop warnings-as-errors.** Not on the table; it is in
[../delivery/definition-of-done.md](../delivery/definition-of-done.md).

**Vendor `NextcloudUI` and patch its manifest.** Fixes the GUI and forks the library the
project exists to give feedback on.

## Revisit when

`NextcloudUI` drops `.treatAllWarnings(as: .error)`, or Xcode stops forcing
`-suppress-warnings` on package targets. Either one lets the manifests hold the setting
again, and lets `make build-app` lose its override.
