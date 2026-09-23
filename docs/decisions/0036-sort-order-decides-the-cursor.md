<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0036: The server-side sort order decides what a cursor means, and the tail scan needs newest-first

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-05, measured against the live server

## Context

[api-payloads.md](../reference/api-payloads.md) already said that the sort order of
`GET /api/messages` "comes from the user's server-side `sort-order` preference, **not** a
parameter", and that a user who set oldest-first "changes what `cursor` means". Nobody had
measured how much.

WS-05 set `sort-order` to `oldest` on the live server, took four readings and set it back.

| | `newest` (or unset) | `oldest` |
| --- | --- | --- |
| Page one of `GET /messages` | the newest 100, descending | the **oldest** 100, ascending |
| `cursor` | exclusive **upper** bound: `dateInt <` | exclusive **lower** bound: `dateInt >` |
| `&sortOrder=newest` in the query | ignored | ignored |

Measured: with the preference set to `oldest`, `limit=5` returned ids 23–27 (the oldest
five), and `&cursor=1776198096` — the `dateInt` of id 23 — returned ids 24–28, which are
*newer* than it. Adding `&sortOrder=newest` to the query changed nothing; the preference is
the only input.

Three things break under `oldest`, and none of them fails visibly:

- **Stage 1 of the backfill** ([local-mirror.md](../architecture/local-mirror.md)) starts
  with no cursor and walks with `oldest dateInt + 1`. Under `oldest` that reads the oldest
  page, then asks for everything newer than its oldest message plus one — which is the same
  page shifted by one row. A 50,000-message mailbox would take 50,000 requests instead of
  500, and the "cursor did not advance" guard never fires because the cursor does advance.
- **The tail scan** is defined as paging "from newest until an entire page is already
  known". Under `oldest` there is no way to ask for the newest page at all: the newest
  messages are at the *end* of the walk.
- **The deep reconcile** inherits stage 1's arithmetic and therefore stage 1's bug.

## Decision

`SyncScheduler` reads `GET /api/preferences/sort-order` once per run and lets it decide.

**The cursor flips with the order.** One function owns it,
`SyncScheduler.nextCursor(after:sortOrder:)`: `min(dateInt) + 1` under `newest`,
`max(dateInt) - 1` under `oldest`. The `± 1` is the same overlap-by-one trick in both
directions and for the same reason — the comparison is strict and `dateInt` is not unique
([ADR-0030](0030-stage-one-owns-its-cursor.md)).

**The tail scan is skipped under `oldest`, not run backwards.** `SyncMetrics.tailScanUnavailable`
records it and the scheduler logs it once per account. The incremental
`POST /sync` still works — it takes `sortOrder` in its body, so it is not affected — so new
mail still arrives; what is lost is the thread siblings `newMessages` omits, and those wait
for the weekly deep reconcile, which still enumerates correctly because its cursor flipped.

## Consequences

An `oldest` account gets a correct mirror and a slower one: a reply to an existing thread
can take up to a week to appear rather than up to two minutes. That is a real degradation
and the app should say so somewhere the user can see it — a note for WS-12's settings
panel, listed in WS-05's report.

Every enumeration in the app now has to ask the scheduler for its cursor rather than
computing `min + 1` inline. That is one function and one call site each, and it is the only
way the two directions cannot drift apart.

**Stage 1 in `NCMailSync/Mirror/**` was still wrong under `oldest`** when this was written:
WS-05 did not own that file and left the fix as a request. It landed on 2026-09-23.
`MirrorCoordinator` reads the preference once per coordinator in `bootstrap` and
`enumerate(_:)` calls `nextCursor(after:sortOrder:)`, which
`MirrorCoordinatorTests.theCursorFlipsForAnOldestFirstAccount` pins from the mirror's side
rather than only from sync's.

## Alternatives considered

**Send `sortOrder` on `GET /messages`.** Measured: ignored. The controller reads the
preference.

**Write the preference to `newest` at sign-in.** One `PUT` and everything works. It also
silently changes what the user sees in the web client, which is not a client's business —
`api-payloads.md` says v1 reads preferences and does not write them, and this is exactly the
kind of "helpful" write that decision exists to prevent.

**Refuse to mirror an `oldest` account.** Honest, and it turns a slower sync into no product
at all for a user who made a reasonable choice in a different client.

**Enumerate the whole mailbox every cycle to find the newest page.** That is the reconcile,
at a two-minute cadence, which is the traffic ADR-0015 exists to avoid.

## Revisit when

The server accepts a sort order per request, or offers a "give me everything since token X"
endpoint — either of which removes the preference from the enumeration entirely. Noted in
[../feedback/server-findings.md](../feedback/server-findings.md).
