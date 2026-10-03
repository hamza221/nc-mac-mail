<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-31 — Triage parity: tags, snooze, quick actions, shortcuts

**Wave 3, after WS-22, WS-25. Size: L.**

## Goal

§4.4/§4.5 actions, §4.7, §4.8 and §2.6.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0049-the-arrow-keys-stay-with-the-list.md](../../decisions/0049-the-arrow-keys-stay-with-the-list.md) — every shortcut is a menu item
- [WS-10-triage.md](WS-10-triage.md) — the v1 brief whose rules still hold

## You own

`NextcloudMail/Actions/**`, `NextcloudMail/Commands/**`

## Build

- Tag modal (set, unset, create, edit, delete).
- Quick actions execution (respecting ACLs). Mark spam/not spam semantics.
- Forward N as attachment → `openComposer`. Edit as new. Move picker with breadcrumbs and
  search.
- Shortcuts: add `C` and `⌘N` compose, `⌘⇧D` send, `⌘S` save draft (composer), and the
  §2.6 table; all registered as menu items (ADR-0049).

Rules that are easy to get wrong:

- **Snooze presets exactly as in §4.4**: Later today 18:00 before 17:00; Tomorrow 08:00;
  This weekend Mon–Thu; Next week except Sunday; custom. Snoozing creates the Snoozed
  folder on first use. Unsnooze exists.
- **Every action goes through the mutation queue** (WS-22's kinds) — no HTTP here, same as
  WS-10.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every action offline and undoable where the web is.

## Out of scope

The queue and its operation kinds (WS-22). Message list rendering and the hover targets
(WS-29). The message view hosting banners (WS-30). The composer the forward and edit-as-new
actions open (WS-27). The sidebar and Snoozed folder display (WS-28).

## Report

Additionally: which actions the web makes undoable that were awkward to invert through the
queue, and how the Snoozed-folder-on-first-use creation behaved offline.
