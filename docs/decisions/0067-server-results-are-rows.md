<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0067: Server-computed results are cached rows

**Status:** Accepted
**Date:** 2026-10-03, confirmed 2026-10-04
**Decided by:** v2 roadmap; confirmed by WS-21, which implements it (`ServerResultFetcher`)

## Context

v2 adds many features whose data the server computes on demand: summaries, translations,
suggestions, quota, Sieve scripts, Files listings and more. The architecture rule since
ADR-0003 is that views read the database and the network only writes to it. Each of these
features is a temptation to let a view await a network call directly.

## Decision

Server-computed results are cached rows.

- Applies to: thread summaries, smart replies, translations, itinerary and event-data
  suggestions, quota, Sieve script text, supplemental recipient suggestions, Files
  listings, Smart Picker results, Teams lists.
- Mechanism: an actor in `NCMailSync` requests the result and writes it into a table; the
  view observes the table and shows a pending state until the row exists.
- This keeps "the network only writes to the database" without exceptions.

### As built (WS-21)

- `ServerResultFetcher` (one actor per login) is the mechanism. `request(kind:key:)` returns
  as soon as the request is registered; the network answer is written, never returned.
- Scalar answers — thread summary, smart replies, translation, itineraries, event data,
  quota, follow-up check, and the bookkeeping row of an autocomplete term — share
  `serverResult`, keyed `(loginId, kind, key)`. List-shaped answers keep their own typed
  tables (`recipientSuggestion`, `filesListing`, `smartPickerResult`, `sieveState`).
- The payload is always `{"status": "ready", "data": …}`, `{"status": "empty"}` (the server
  answered and had nothing — the 204 of an instance without an LLM provider) or
  `{"status": "failed", "error": …}` with a short error name. Three states, because a view
  has to stop its pending indicator on "nothing" and on failure, and tell those apart.
- **A failure never overwrites a `ready` row.** A stale answer beats an error, and offline
  is not the moment to lose one. Offline, nothing is sent and nothing is touched.
- Expiry per kind lives in `ServerResultKind.expiry`; a `failed` row allows one retry per
  five minutes, and an `empty` row is re-asked after at most fifteen minutes
  (`emptyRetryAfter`), because "nothing" is the answer an admin switch (LLM processing)
  flips for a whole instance at once. The same `(kind, key)` in flight is joined, not
  repeated.

## Consequences

- Every view keeps the same shape: observe a table, render rows, show pending until a row
  exists. Results survive relaunch and are shared between views for free.
- The cost is a table per result kind and stale rows. Each row carries `fetchedAt`, and
  each owning workstream sets its own expiry.

## Alternatives considered

**Views await the network call directly.** Breaks "the network only writes to the
database", loses the result on relaunch, and gives each feature its own loading and error
plumbing.

**One generic key–value cache table for everything.** Rows lose their types and their
observability. As built this is half-taken, deliberately: the scalar kinds share
`serverResult`, because each is one JSON value a view decodes whole, while anything a view
queries into — suggestions, listings, Sieve state — keeps a typed table.

## Revisit when

The number of result tables makes the schema unmanageable, or the server offers push
invalidation for computed results.
