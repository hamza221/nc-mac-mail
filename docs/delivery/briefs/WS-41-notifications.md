<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-41 — Notifications, dock badge, Nextcloud notifications

**Wave 5, after WS-25. Size: M.**

## Goal

§2.3 and the Notifications-app rows, natively.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [ADR-0003](../../decisions/0003-local-first-full-mirror.md)
- [ADR-0064](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [ADR-0071](../../decisions/0071-widgets-read-snapshot.md) — the widget boundary; you
  notify, WS-42's widgets read the snapshot

## You own

`NextcloudMail/Notifications/**`

## Build

- `MailNotifier` observes new inbox rows inserted by sync after the account's initial
  mirror is complete (no notification storm on first sync).
- Content: sender and subject (the content preview follows the system "Show previews"
  setting); grouped per thread; actions Archive, Mark read, Reply.
- Suppressed while the main window is key and showing that mailbox.
- Dock badge = unread count over every account's inbox.
- Nextcloud notifications OCS poll every 5 min for `app == "mail"` (quota, delegation) →
  native notifications.

Rules that are easy to get wrong:

- **No notification storm on first sync**: only rows inserted after the account's initial
  mirror completes notify.
- Notification actions go through the mutation queue, so Archive from the banner works
  offline like any other triage action.

Universal rules:

- Your first commit updates [`docs/product/ux-spec.md`](../../product/ux-spec.md) with the
  screens/behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in
  [`docs/product/parity.md`](../../product/parity.md) in your PR, with the evidence (test
  name or manual check) in the note column.

## Acceptance

- A mail sent from the web client notifies within one sync cycle.
- Archive from the notification works offline.

## Out of scope

Spotlight, widgets, Share extension and everything else under §10 system integration
(WS-42). The sync pass that inserts the rows you observe (WS-21). Unread counts rendered
inside the app's sidebar and list (WS-28, WS-29).

## Report

Additionally: how initial-mirror completion is detected per account, and how noisy the
5-minute OCS poll is in practice.
