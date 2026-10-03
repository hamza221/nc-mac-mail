<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-35 — Contacts: browse, view, edit

**Wave 4, after WS-24 and WS-25. Size: XL.**

## Goal

[ADR-0070](../../decisions/0070-contacts-sidebar-section.md) and the core of Contacts
parity: browse, view and edit every contact, offline included.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — the Contacts table
- [../../decisions/0069-contacts-same-database.md](../../decisions/0069-contacts-same-database.md)
- [../../decisions/0070-contacts-sidebar-section.md](../../decisions/0070-contacts-sidebar-section.md)

## You own

`NextcloudMail/Views/Contacts/**` except `AddressBooks/**` and `Teams/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **`ContactsSidebarSection`** — you hold standing exception 1: the single line embedding it
  into `NextcloudMail/Views/Sidebar/SidebarView.swift` is your one cross-boundary edit.
- **Contact list**: favorites first, sort per the Contacts setting, search via
  `contactSearch`, multi-select hand-off to WS-36.
- **Detail pane** headed by NextcloudUI `NCProfileCard`, with view and edit modes for every
  typed `VCard` property, plus "other properties" preserved read-only.
- **Photo**: upload, crop, remove, full size, download, social fetch.
- **Groups** (CATEGORIES). **Favorites** (the Contacts app's favourite marker — confirm
  which vCard property it uses before writing).
- **New and delete contact.** "New message" and `RecentMailList` from WS-26.
- **Read-only address books disable editing with a reason.**
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every WS-35 contacts row live, offline included.

## Out of scope

The contacts mirror and vCard parsing (WS-24, WS-17). Address books, import/export, merge,
batch (WS-36). Teams (WS-37). Recipient suggestions and sender cards (WS-26). The sidebar
itself beyond exception 1 (WS-28).

## Report

Additionally: which vCard property the Contacts app uses for favourites, and whether
"other properties" survived an edit round-trip untouched.
