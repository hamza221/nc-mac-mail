<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-34 — Calendar integration

**Wave 4, after WS-24 and WS-30. Size: L.**

## Goal

§5.9 parity: invitations, tasks and itineraries handled from the message view, written
through the calendar mirror.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — §5.9
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md)
  — itinerary and event-data suggestions are cached rows

## You own

`NextcloudMail/Views/Calendar/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **iMIP card**: REQUEST/REPLY/CANCEL states; accept/decline/tentative with comment and
  "Save to" calendar, written via `calendarPut` (the server's scheduling sends the reply —
  confirm on the live server).
- **Reply-with-meeting sheet** (AI title and description via eventdata).
- **Create task** (VTODO calendars).
- **Itinerary cards** with import, de-duplicated by UID.
- **`.ics` attachment import.**
- The `imipCreate` setting UI lives in WS-39.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Accept an invite and the organiser receives the reply (live).

## Out of scope

The calendar mirror itself (WS-24). The message view that hosts the cards (WS-30). The
`imipCreate` account setting (WS-39). Contacts views (WS-35).

## Report

Additionally: whether `calendarPut` alone was enough for the scheduling reply on the live
server, or the server needed something more.
