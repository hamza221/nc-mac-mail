<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-24 — Contacts and calendars mirror

**Wave 2, after WS-17, WS-18, WS-22. Size: XL.**

## Goal

[ADR-0069](../../decisions/0069-contacts-same-database.md). A complete, offline-editable
mirror of every address book, plus the calendar list, per Nextcloud login.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0069-contacts-same-database.md](../../decisions/0069-contacts-same-database.md) — keying by `AccountSession`, sync protocol, 412 handling
- [../../decisions/0061-avatars-are-fetched-into-the-mirror-by-sync.md](../../decisions/0061-avatars-are-fetched-into-the-mirror-by-sync.md) — names the avatar path
- [../../architecture/sync-engine.md](../../architecture/sync-engine.md)

## You own

`NCMailSync/Contacts/**`, `NCMailSync/Calendar/**`

## Build

- Your first commit updates [../../architecture/sync-engine.md](../../architecture/sync-engine.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

`actor ContactsSync` in `NCMailSync/Contacts/`:

- discovery, address book list (including enabled state, read-only, shared-by, sync token);
- `sync-collection` loop (every 10 min, and on wake);
- multiget batches of 100;
- writes via the queue kinds from WS-22 with `If-Match`;
- 412 → refetch, reapply local edits per property, retry once, otherwise surface a conflict
  row.

`actor CalendarListSync` in `NCMailSync/Calendar/`: calendars with components
(VEVENT/VTODO), writability, colour and the default schedule calendar.

Rules that are easy to get wrong:

- Contact photos are written into the existing `avatar` table by email, **ahead of server
  avatars** ([ADR-0061](../../decisions/0061-avatars-are-fetched-into-the-mirror-by-sync.md)
  names this path).
- Social avatar fetch: the Contacts app route, **unverified — confirm against the live
  server first**.

## Acceptance

- A 2,000-contact system address book mirrors in under 60 s (measure and write the number
  down).
- Offline edit → reconnect → visible in web Contacts.
- Concurrent web edit to a different field merges; to the same field, local wins and the
  conflict is logged.

## Out of scope

The DAV client, vCard and iCalendar types (WS-17). The tables (WS-18). The queue kinds you
drain (WS-22). Starting the actors per session (WS-25). Contacts UI (WS-35, WS-36, WS-37),
calendar UI (WS-34), recipient suggestions (WS-26).

## Report

Additionally: the measured 2,000-contact mirror time, the confirmed social-avatar route, and
how often the 412 path fell through to a conflict row in testing.
