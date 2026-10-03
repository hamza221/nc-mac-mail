<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-33 — Files picker and Files actions

**Wave 3, after WS-17, WS-18, WS-25. Size: M.**

## Goal

Everything that touches Nextcloud Files.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md) — listings are cached rows

## You own

`NextcloudMail/Views/Files/**`, `NCMailSync/Files/**`

## Build

- `FilesListingSync` in `NCMailSync/Files/` (PROPFIND listings into `filesListing` per
  ADR-0067).
- `FilesPicker` sheet: browse, breadcrumbs, filter by type, multi-select; "Choose a folder"
  mode.
- Actions: attach file, insert image (≤ 10 MB, png/jpeg/gif/bmp/webp), add as share link
  (files_sharing OCS), save attachment / all attachments / message to Files.

Rules that are easy to get wrong:

- **The picker reads `filesListing` rows, never the network directly** (ADR-0067): the view
  observes the table and shows a pending state until the row exists.
- **Insert image enforces the limit and types**: ≤ 10 MB, png/jpeg/gif/bmp/webp only.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Each action live.
- The picker shows the cached listing offline with an offline note.

## Out of scope

The DAV client the sync calls (WS-17). The store tables (WS-18). The composer's attachments
strip that opens the picker (WS-27). The message view's save-to-Files entry points (WS-30).

## Report

Additionally: how stale the cached listings got in practice and what expiry you set per
ADR-0067, and whether files_sharing OCS matched the documented routes.
