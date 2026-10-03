<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-00 — Project skeleton, packages, CI, lint

**Wave 0. Nothing else starts until this merges. Size: M.**

## Goal

A repository where `xcodebuild` builds an empty app, `swift test` runs in five packages,
and CI enforces both — so every later workstream adds code rather than infrastructure.

## Before you start

- [../../architecture/overview.md](../../architecture/overview.md) — module map
- [../../decisions/0013-module-layout.md](../../decisions/0013-module-layout.md) — why the packages are split this way
- [../../decisions/0001-xcode-project-in-git.md](../../decisions/0001-xcode-project-in-git.md) — why Xcode
- [../../architecture/concurrency.md](../../architecture/concurrency.md) — isolation per module
- `hamza221/nextcloud-swiftui`: `Package.swift`, `Makefile`, `.swiftlint.yml`, `.swift-format`, `CONTRIBUTING.md` — match its conventions where they fit

## You own

`NextcloudMail.xcodeproj/**`, `Packages/*/Package.swift`, `Packages/*/Sources/*/Placeholder.swift`,
`.github/**`, `Makefile`, `.swiftlint.yml`, `.swift-format`, `.gitignore`, `REUSE.toml`, `LICENSES/`

## Build

**The Xcode project.** App target `NextcloudMail`, macOS 26, Swift 6 language mode, bundle
id `com.nextcloud.mail.macos`. App Sandbox with `com.apple.security.network.client` and
nothing else. Hardened runtime on. A `NavigationSplitView` with three placeholder columns
and `.ncTheme(.nextcloud)` at the scene root, so M0 is visibly an app.

Keychain caveat, **measured and closed by WS-00**: an ad-hoc signature does not block
`SecItem`. A bundle signed `codesign --sign - --options runtime` with these entitlements
runs inside its container and gets `errSecSuccess` from `SecItemAdd`, `SecItemCopyMatching`
and `SecItemDelete` on macOS 26. The sandbox stays on. What the ad-hoc signature does drop
is the hardened runtime — see [../../decisions/0018-ad-hoc-signature-in-the-checked-in-project.md](../../decisions/0018-ad-hoc-signature-in-the-checked-in-project.md).

**Five packages** under `Packages/`, each with its own manifest:

| Package | Depends on | `defaultIsolation` |
| --- | --- | --- |
| `NCMailCore` | — | none |
| `NCMailNet` | Core | none |
| `NCMailStore` | Core, GRDB | none |
| `NCMailSync` | Core, Net, Store | none |
| `NCMailTestSupport` | Core, Net, Store | none — **test-only**, never a dependency of the app target |

`NCMailTestSupport` exists because a SwiftPM test target cannot reference files outside its
own package, and the recorded fixtures are shared by all of them (WS-14 fills it; you create
it empty with the fixtures resource directory wired up).

Shared settings in every manifest, matching the library:

```swift
let shared: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
```

`.treatAllWarnings(as: .error)` was in this list and had to come out: Xcode gives every
package target `-suppress-warnings` and swiftc rejects the pair, so the app did not build at
all. Warnings-as-errors moved to `swift build -Xswiftc -warnings-as-errors`, which covers
the same targets. [ADR-0016](../../decisions/0016-warnings-as-errors-at-the-build-command.md)
has the measurements.

The app target gets `defaultIsolation(MainActor.self)`; the packages do **not** — see the
concurrency document for why that would be expensive.

**Dependencies:** `NextcloudUI` (branch `main`) on the app target, GRDB (from 7.0.0) on
`NCMailStore`. Nothing else without an ADR.

**Tooling.** `Makefile` with `setup`, `build`, `test`, `lint`, `format`, `app`.
`.swiftlint.yml` and `.swift-format` adapted from the library, plus a custom rule banning
`Image(systemName:)` outside `MailSymbol.swift` and one banning `print(`.

**CI** (`.github/workflows/ci.yml`): package build and test with warnings as errors, lint,
`xcodebuild build` on a macOS runner with Xcode 26, Thread Sanitizer on package tests.
Cache SwiftPM. Fail on warnings.

**REUSE compliance** from the first commit, matching the library: SPDX headers or a
`REUSE.toml` glob for every file, AGPL-3.0-or-later.

## Acceptance

- `make build`, `make test`, `make lint` all pass on a clean checkout.
- `make build-app` is clean. Bare `xcodebuild -scheme NextcloudMail build` was **not**, and
  could not be until `NextcloudUI` stopped setting `.treatAllWarnings(as: .error)` — which
  it did in `1e753cb`, after this project reported it. Both work now.
  `make build-app` still adds `SUPPRESS_WARNINGS=NO`, which is what keeps a warning in one
  of our own packages visible in an app build. ADR-0016.
- The app launches and shows three empty columns wearing the Nextcloud brand colour.
- CI is green on a pull request, and demonstrably red when a warning is introduced.
- `swift test` runs in all five packages with zero tests and no errors.
- A file added to a package needs no `.pbxproj` edit. Prove it in the report.

## Out of scope

Any product code. Signing and notarization beyond leaving hardened runtime on. Release
automation. If you find yourself writing a model, stop — that is WS-02.

## Report

Additionally: the exact Xcode and Swift versions used; whether `SecItem` worked under the
sandbox with an ad-hoc signature; and how long a clean CI run takes, because everyone pays
that number on every push.
