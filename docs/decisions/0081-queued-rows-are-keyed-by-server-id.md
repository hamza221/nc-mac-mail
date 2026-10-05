<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0081: Queued v2 settings rows are named by server id; offline creates get negative placeholders

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-22, while adding the v2 queue kinds

## Context

ADR-0033 says rows take local ids and requests take `remoteId`, and v1's queue kinds name
messages by local id. The v2 settings tables WS-18 added — `textBlock`, `quickAction`,
`quickActionStep`, `alias`, `tag` — are refreshed by *replacement*: the mirror deletes the
login's or account's rows and inserts the server's list, so every refresh assigns fresh local
ids. A queued `updateTextBlock` that named local id 7 would, after the next sync, name a row
that no longer exists or a different one.

A create made offline has the opposite problem: it has no server id at all until it drains,
yet the user can edit, share or delete it — and queue those edits — before it does. Those
tables declare `remoteId NOT NULL` and unique within their scope, so the optimistic row needs
*some* value there.

## Decision

- Every v2 kind that names a settings row (tag, alias, text block, quick action, action step,
  mailbox) names it by **server id**, and the store's row effects are keyed the same way.
- An offline create gets a **negative placeholder** `remoteId`, drawn at random from the
  negative `Int64` range so two creates in the same second cannot collide and no real id
  ever can.
- When the create drains, one transaction deletes the queue row, writes the server's id over
  the placeholder in the mirror and records `meta["queue.placeholder.<family>.<placeholder>"]
  = <server id>`.
- At send time every negative id in a payload is resolved through that map. One that does not
  resolve means its create was discarded or never existed; the row is dropped as a 404 is.

## Consequences

- Updates, shares, steps and deletes of an offline-created row queue normally and go out with
  the right id, whether or not the create had already drained when they were queued.
- A replacement sync between queueing and draining does not orphan a queued row.
- The `meta` table gains one small row per offline create. They are never read after the
  rows that named the placeholder have drained; pruning them is not worth a code path.
- Message-scoped kinds keep ADR-0033's local ids: `message` rows are upserted, not replaced,
  so their local ids are stable.

## Alternatives considered

**Name rows by local id, as v1 does.** Breaks on the first replacement refresh.

**Make the replacement DAOs upsert instead.** Right in the long run, and the row effects in
`LocalEffect.rows` already upsert; but the sync paths that replace are WS-21's and WS-18's,
and server-id naming is correct whichever way they end up writing.

**Collapse a create with everything queued after it for the same row.** Handles the common
case and not the one where the create was already in flight when the edit was queued; the
placeholder map handles both.

## Revisit when

The settings tables keep stable local ids across refreshes, at which point local-id naming
becomes possible again and consistent with ADR-0033.
