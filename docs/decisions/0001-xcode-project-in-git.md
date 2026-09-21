<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0001: Check an Xcode project into git rather than ship a pure SwiftPM app

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Carried over from `plan/macos-client.md`, confirmed against the library's own roadmap

## Context

`NextcloudUI` ships 91 Material Design Icons as `.symbolset` assets in an asset catalogue.
SwiftPM copies an asset catalogue into a bundle **without compiling it**: there is no
`Assets.car`, and `NCIcon` detects this and falls back to SF Symbols. The library's
`docs/ROADMAP.md` records this as an open item, and its README tells you plainly that
`swift run NextcloudShowcase` shows fallbacks while Xcode shows the real glyphs, because
Xcode runs `actool`.

An app whose entire visual identity is "this looks like Nextcloud" cannot ship with the
wrong icons.

The app also needs things a SwiftPM executable does not get for free: an `Info.plist`, a
bundle identifier, entitlements, Keychain access that depends on a signed bundle,
`WKWebView`, a Settings scene, and a route to notarization.

## Decision

The app target lives in `NextcloudMail.xcodeproj`, checked into git. The non-UI
modules are local Swift packages the project depends on ([ADR-0013](0013-module-layout.md)),
so almost everything is still testable with `swift test`.

## Consequences

- Icons render correctly, because `actool` runs.
- Entitlements, signing and notarization have somewhere to live.
- `xcodebuild` is required for the app target; CI needs a macOS runner with Xcode 26.
- `project.pbxproj` is in git, which is a merge-conflict surface. Mitigation: file
  references are added in one workstream at a time (WS-00 owns the project file; everyone
  else owns package sources), and the file-ownership table in
  [../delivery/workstreams.md](../delivery/workstreams.md) is written around this.
- Package tests run without Xcode, so most CI work is fast.

## Alternatives considered

**Pure SwiftPM executable.** Free of the `.pbxproj`, but ships with SF Symbol fallbacks and
no home for entitlements. Rejected on the icons alone.

**SwiftPM plus a build-tool plugin that runs `actool`.** The library's `CONTRIBUTING.md`
argues against this: a plugin taxes every incremental build for every consumer. Not ours
to impose, and it would not solve entitlements.

**XcodeGen or Tuist generating the project.** Removes the `.pbxproj` conflicts at the cost
of a generator dependency and a second source of truth. Worth revisiting if the project
file becomes a real problem; not worth the ceremony on day one.

## Revisit when

SwiftPM compiles asset catalogues, or `.pbxproj` conflicts cost more than one afternoon.
