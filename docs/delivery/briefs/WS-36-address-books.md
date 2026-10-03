<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-36 — Address books, import/export, merge, batch

**Wave 4, after WS-35. Size: L.**

## Goal

The remaining Contacts parity rows: address book management, vCard import/export, merge
and batch operations.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — the Contacts table
- [../../decisions/0069-contacts-same-database.md](../../decisions/0069-contacts-same-database.md)

## You own

`NextcloudMail/Views/Contacts/AddressBooks/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **Address book management sheet**: create, rename, enable/disable, share with user or
  group (read-only toggle), export `.vcf`, delete, copy CardDAV URL.
- **vCard import** (3.0/4.0, choose the target book).
- **Merge two contacts** (radio for single-value properties, checkboxes for multi-value;
  groups union by default).
- **Batch delete.**
- **Contacts settings**: sort order and social auto-update.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Import a 500-contact file offline, then reconnect and they all sync.

## Out of scope

Contact browsing, viewing and editing (WS-35). Teams (WS-37). The contacts mirror and sync
loop (WS-24). The DAV client and vCard value types (WS-17).

## Report

Additionally: how the 500-contact offline import behaved on reconnect — one batch or a
long drain — and whether merge needed any property handling the radio/checkbox model did
not cover.
