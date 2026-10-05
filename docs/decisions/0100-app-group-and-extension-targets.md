<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0100: A team-prefixed app group, ad-hoc-signed extensions, one shared source folder

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-42

## Context

WS-42 adds two app extensions — widgets (ADR-0071) and Share — that exchange files with the
app through an app group. The checked-in project signs ad hoc with no team and no profile
(ADR-0018), and `make build-app` must build every target on any Mac and on CI.

WS-27 had already spelled the group `group.com.nextcloud.mail.macos` in `SharedInbox`. With
that identifier in the entitlements, `xcodebuild` refuses all three targets: *"requires a
provisioning profile"*. On macOS a `group.`-prefixed group must be authorised by a profile;
the team-prefixed form (`<TEAMID>.<name>`) needs none.

## Decision

- **Identifier.** Every target's entitlement is
  `$(TeamIdentifierPrefix)com.nextcloud.mail.macos`. Ad hoc it expands to
  `com.nextcloud.mail.macos`; signed by a team, to `TEAMID.com.nextcloud.mail.macos`. Each
  target's Info.plist carries the same expansion under `NCMailAppGroup`, and
  `AppGroup.identifier` reads it, so the code always names the group the binary is entitled
  to. `SharedInbox.appGroupIdentifier` delegates to it (one line in WS-27's file).
- **Signing.** The extensions copy the app's settings: `CODE_SIGN_STYLE = Manual`,
  `CODE_SIGN_IDENTITY = "-"`, hardened runtime on, sandbox on. No scheme change: the app
  target depends on both extensions and embeds them (`Embed Foundation Extensions`, PlugIns),
  so the existing `NextcloudMail` scheme builds all four targets.
- **Shared code.** `NextcloudMailShared/` is a synchronised folder that is a member of the
  app and both extensions: the app-group identifier, the widget snapshot format, the Share
  inbox writer and `SystemLink`. The test target reaches them through `@testable import
  NextcloudMail`, which is how `ShareHandoffTests` proves the writer the extension runs and
  the reader the composer runs agree.
- **Info.plist.** The app keeps `GENERATE_INFOPLIST_FILE`; `NextcloudMail/System/Info.plist`
  adds only what build settings cannot spell (`CFBundleURLTypes`, `NSServices`,
  `NCMailAppGroup`) and is excluded from the synchronised folder's resources.

## Consequences

- `make build-app` builds the app, the widgets and the Share extension; no account needed.
- An ad-hoc build's group container is `~/Library/Group Containers/com.nextcloud.mail.macos`.
  macOS protects it (a shell gets "Operation not permitted"); the sandboxed app and its
  tests read and write it (`ShareHandoffTests`, `AppGroupTests`).
- Whether macOS loads ad-hoc-signed extensions into Notification Center's widget gallery
  and the share sheet depends on the user allowing them (System Settings ▸ Extensions); a
  Developer ID build is what makes that reliable. The release pipeline (ADR-0018's open
  item) owns it.
- A Developer ID build changes the group's on-disk name (team prefix). Nothing persistent
  lives there except the snapshot and unopened Share items, both disposable.

## Alternatives considered

**Keep `group.` and add a provisioning profile.** Builds on one developer's machine only —
the reason ADR-0018 exists.

**`CODE_SIGNING_ALLOWED = NO` for the extensions.** An unsigned extension has no
entitlements, so no sandbox and no group container; the hand-off could not be tested.

**Copy the shared files into each target.** Two copies of the hand-off format, which is the
drift the shared folder and its test exist to prevent.

## Revisit when

A release pipeline signs with a team, or Apple lets ad-hoc builds carry `group.` identifiers.
