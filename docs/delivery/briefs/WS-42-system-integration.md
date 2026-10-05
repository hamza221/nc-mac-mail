<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-42 — System integration: default mail app, mailto, Spotlight, widgets, Share extension, Services

**Wave 5, after WS-25, WS-27. Size: L.**

## Goal

Native equivalents of §10 web integrations.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [ADR-0003](../../decisions/0003-local-first-full-mirror.md)
- [ADR-0064](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [ADR-0071](../../decisions/0071-widgets-read-snapshot.md) — widgets read a snapshot file
  in the app group, never the database

## You own

`NextcloudMail.xcodeproj/**`, the new extension target folders, `NextcloudMail/System/**`

## Build

- Incoming URLs: handle `mailto:` → `openComposer(.new(mailto:))` and the
  `ncmail://open/<Message-ID>` scheme (register both in Info.plist). Setting the default
  mail app is WS-38's button; this workstream only receives the URLs.
- Spotlight: `CSSearchableIndex` for messages and contacts, updated from store
  observations; opening a result selects the message or contact.
- WidgetKit extension target with Important and Unread widgets (ADR-0071).
- Share extension target: files/URLs → app-group inbox → `ComposeRequest.shared`.
- Services menu: "New Nextcloud Mail message with selection".
- App group entitlement. All project edits are owned here.

Rules that are easy to get wrong:

- **You own every project-manifest edit** — `NextcloudMail.xcodeproj/**` and `Package.swift`
  files, Info.plist, entitlements, the new extension targets. Other workstreams request
  manifest changes from you; none makes them itself.
- Widgets never open the database: they read `widget-snapshot.json` from the app-group
  container (ADR-0071).

Universal rules:

- Your first commit updates [`docs/product/ux-spec.md`](../../product/ux-spec.md) with the
  screens/behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in
  [`docs/product/parity.md`](../../product/parity.md) in your PR, with the evidence (test
  name or manual check) in the note column.

## Acceptance

- Each integration demonstrated on a clean user account.

## Out of scope

The "Set as default mail app" button in settings (WS-38) — you only receive the URLs once
the app is the handler. The composer that `mailto:` and the Share extension open (WS-27).
New-mail notifications and the dock badge (WS-41). The sync pass whose store observations
feed Spotlight and the widget snapshot (WS-21).

## Report

Additionally: what the extension targets did to the build, and whether the app-group inbox
handoff to `ComposeRequest.shared` was reliable from the Share extension sandbox.
