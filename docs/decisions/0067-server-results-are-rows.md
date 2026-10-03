<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0067: Server-computed results are cached rows

**Status:** Proposed
**Date:** 2026-10-03
**Decided by:** v2 roadmap, to be confirmed by the owning workstream

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

## Consequences

- Every view keeps the same shape: observe a table, render rows, show pending until a row
  exists. Results survive relaunch and are shared between views for free.
- The cost is a table per result kind and stale rows. Each row carries `fetchedAt`, and
  each owning workstream sets its own expiry.

## Alternatives considered

**Views await the network call directly.** Breaks "the network only writes to the
database", loses the result on relaunch, and gives each feature its own loading and error
plumbing.

**One generic key–value cache table.** Rows lose their types and their observability;
per-kind tables keep queries and expiry honest.

## Revisit when

The number of result tables makes the schema unmanageable, or the server offers push
invalidation for computed results.
