<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-17 — DAV client, vCard and iCalendar

**Wave 1, no dependencies. Size: L.**

## Goal

A CardDAV/CalDAV/WebDAV client and lossless formats, with no UI.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0069-contacts-same-database.md](../../decisions/0069-contacts-same-database.md) — placement and the lossless-vCard decision
- [../../architecture/networking.md](../../architecture/networking.md) — you reuse `MailTransport`

## You own

`NCMailNet/DAV/**`, `NCMailCore/Contacts/**`, `NCMailCore/Calendar/**`

## Build

- Your first commit updates [../../architecture/networking.md](../../architecture/networking.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

In `NCMailNet/DAV/`:

- `DAVClient` (a `Sendable` struct using the existing `MailTransport` and credentials).
- `propfind(_ url:, depth:, properties:)`, `report(_ url:, body:)`,
  `syncCollection(_ url:, token:)` returning
  `(changed: [DAVResource], removed: [URL], newToken: String)`.
- `addressbookMultiget`, `calendarMultiget`, `put(_ url:, data:, contentType:, ifMatch:)`
  returning the ETag, `delete(_ url:, ifMatch:)`, `mkcolExtended`, `proppatch`.
- `share(_ url:, with:, readOnly:)` (Nextcloud `oc:share` POST).
- Principal discovery: current-user-principal → addressbook-home-set and calendar-home-set.
- XML via Foundation `XMLParser`; **no new dependency** (definition of done).

In `NCMailCore/Contacts/`:

- `VCard` — ordered properties preserving group, name, parameters and raw value; typed
  accessors for N, FN, NICKNAME, ORG, TITLE, EMAIL, TEL, ADR, URL, IMPP, X-SOCIALPROFILE,
  BDAY, ANNIVERSARY, NOTE, RELATED, CATEGORIES, PHOTO, UID, REV.
- `VCardParser` — 3.0 and 4.0, line unfolding, quoted-printable for 2.1-style imports.
- `VCardSerializer` — re-emits unknown properties byte-equivalent.

In `NCMailCore/Calendar/`:

- `ICalendar` with VEVENT/VTODO/VTIMEZONE read/write sufficient for iMIP
  REQUEST/REPLY/CANCEL, PARTSTAT and X-RESPONSE-COMMENT, plus event/task creation.

## Acceptance

- Parsing then serialising each recorded vCard fixture yields identical bytes, modulo line
  folding.
- `syncCollection` is tested against recorded REPORT responses, including a 507 truncated
  sync.
- Principal discovery works on the live server (manual check in the PR).

## Out of scope

Mail API endpoints (WS-16). Store tables for contacts and calendars (WS-18). The contacts
and calendars sync engine that drives this client (WS-24). Any contacts or calendar UI
(WS-34, WS-35, WS-36, WS-37).

## Report

Additionally: any vCard property the round trip could not preserve and why, and any place the
Nextcloud DAV server deviated from the RFCs.
