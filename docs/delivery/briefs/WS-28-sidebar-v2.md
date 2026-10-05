<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-28 — Sidebar and mailbox management

**Wave 3, after WS-21, WS-22, WS-25. Size: L.**

## Goal

§3 parity.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0068-settings-commands.md](../../decisions/0068-settings-commands.md) — remove account and repair go through commands

## You own

`NextcloudMail/Views/Sidebar/**`, `NCMailCore/MailboxTree.swift`

## Build

- Virtual entries: Priority inbox, All inboxes (> 1 account), Favorites under each inbox,
  Outbox (when non-empty).
- Account menu: quota, show only subscribed, add folder, move up/down, remove account (via
  `SettingsCommands.deleteAccount`), delegate.
- Folder menu: every item in §3.3 through the queue kinds. Repair goes through the command,
  with 429 handled.
- Drop targets for drag and drop. Provisioned/disabled account row.

Rules that are easy to get wrong:

- **The Contacts section slot (standing exception 1 in the workstreams table) stays empty
  until WS-35 adds it.** Do not build or stub it.
- **Folder mutations are queue kinds**, not HTTP: create/rename/delete and the rest of the
  §3.3 menu go through the mutation queue. The exceptions are remove account and repair,
  which are `SettingsCommands` (ADR-0068) — repair must handle 429.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every §3 row live.
- Folder create/rename offline → appears after reconnect.

## Out of scope

The server-state mirror that fills the tree (WS-21). The queue kinds and settings commands
you call (WS-22). The message list the sidebar selects into (WS-29). The Contacts sidebar
section (WS-35). The app shell and account switching (WS-25).

## Report

Additionally: how the 429 on repair surfaced to the user, and whether the virtual entries
needed anything from the mirror that WS-21 did not already provide.
