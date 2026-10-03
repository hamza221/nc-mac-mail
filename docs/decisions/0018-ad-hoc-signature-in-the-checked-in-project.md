<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0018: The checked-in project signs ad hoc

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** WS-00, needing a project that builds on a CI runner with no Apple account

## Context

The app is sandboxed and asks for `com.apple.security.network.client`
([ADR-0006](0006-data-at-rest.md)), and WS-00's brief says to leave hardened runtime on.
Automatic signing needs a `DEVELOPMENT_TEAM`, which is per-developer and absent on a GitHub
runner, so committing one makes the project build on exactly one machine.

The brief also anticipated that an ad-hoc signature might break Keychain access and offered
to develop with the sandbox off. Measured instead: a probe bundle signed `codesign --sign -
--options runtime` with this project's entitlements ran with `APP_SANDBOX_CONTAINER_ID` set
and `NSHomeDirectory()` inside the container, and `SecItemAdd`, `SecItemCopyMatching` and
`SecItemDelete` each returned `errSecSuccess`. The caveat does not apply on macOS 26.

## Decision

`CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"`, no team, no provisioning profile.
`ENABLE_HARDENED_RUNTIME = YES` stays set. The sandbox stays on, in every configuration,
for every developer.

## Consequences

- The project builds on any Mac and on CI with no account, no team and no profile.
- Hardened runtime is **not actually applied** to a local build. Xcode says so:
  `note: Disabling hardened runtime with ad-hoc codesigning`. The setting is on, so a build
  signed with a Developer ID gets it; nothing local does.
- Keychain works under the sandbox, so WS-01 can use `SecItem` directly and no one has to
  run with the sandbox off.
- A Developer ID build, notarization and a distributable artefact are still missing. Out of
  scope for WS-00 and unclaimed by any workstream.
- Anyone who wants a locally signed build overrides `CODE_SIGN_IDENTITY` and
  `DEVELOPMENT_TEAM` on the command line. The README's development section says how.

## Alternatives considered

**Automatic signing with a committed team id.** One developer's build works and everybody
else's, plus CI, fails.

**`CODE_SIGNING_ALLOWED = NO`.** Builds fastest and produces an unsigned bundle, which the
sandbox refuses to apply entitlements to — so the app would not be running under the
conditions it ships under, and this ADR's Keychain measurement could not have been made.

## Revisit when

Release automation lands, or a workstream needs an entitlement that ad-hoc signing cannot
carry.
