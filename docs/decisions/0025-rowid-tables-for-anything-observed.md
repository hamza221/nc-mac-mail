<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0025: Only unobserved tables may be `WITHOUT ROWID`

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-03, from a test that hung

## Context

Version 1 of `schema.sql` declared five tables `WITHOUT ROWID`: `messageAddress`,
`attachment`, `messageTag`, `avatar` and `meta`. Each has a natural primary key and narrow
rows, which is exactly what the optimisation is for.

An observation test on `meta` never finished. It received its first value, the write landed,
and the second value never arrived — no error, no timeout, just a task waiting forever.

The cause is in SQLite rather than in GRDB. `ValueObservation` is built on
`sqlite3_update_hook`, and [that hook is not invoked for `WITHOUT ROWID`
tables](https://www.sqlite.org/c3ref/update_hook.html). GRDB has no way to know a write
happened, so the observation is not wrong, it is silent. Measured both ways in
`ObservationTests`: an insert into `tag`, a rowid table, delivers a fresh value; the same
insert into `avatar` delivered nothing until this decision changed the table.

Silence is the worst available failure here. A missing index is slow and a bad query throws,
but an observation that never fires looks exactly like a mailbox with no new mail.

Three of the five tables are things a view wants to watch:

- **`avatar`** — the sidebar and the list draw a sender's picture as soon as it is fetched.
- **`attachment`** — the message view shows an inline image once the renderer has pulled it.
- **`meta`** — the backfill pause flag and the sidebar's expansion state.
- **`messageTag`** — a tag added to a message should redraw its row.

`messageAddress` is not. The list reads the denormalised `fromEmail` and `fromLabel` off
`message`; nothing in the UI reads an address row.

## Decision

`WITHOUT ROWID` is allowed only on a table nothing observes. `attachment`, `messageTag`,
`avatar` and `meta` become ordinary rowid tables. `messageAddress` keeps the optimisation and
carries a comment in `schema.sql` saying why it may.

`MigrationTests.messageAddressIsTheOnlyTableWithoutARowid` asserts the rule against
`sqlite_master`, so a future table added `WITHOUT ROWID` fails the build rather than producing
a view that quietly stops updating.

## Consequences

- Every table a view can observe delivers changes. `ObservationTests` covers `message`,
  `mailbox`, `account`, `avatar` and `meta`.
- Four tables gain a rowid and a unique index for the primary key they used to be clustered
  on. On `attachment`, the only one with any volume, that is one index over a handful of rows
  per message — the blobs it stores dwarf it.
- The rule has to be remembered when a table is added. That is what the test is for.
- `messageAddress` stays clustered, which is where the optimisation was actually earning
  something: five to forty narrow rows per message and a composite key.

## Alternatives considered

**Leave the schema alone and never observe those tables.** Every avatar and inline image would
need the app to invalidate something by hand, from the code that did the write, across a
module boundary. That is the coupling the local-first design exists to remove: a view reads
the database and does not care who wrote it.

**Observe a rowid table that changes at the same time.** `ValueObservation` can be told to
track a region wider than the query reads, so an avatar observation could watch `message`
instead. It fires on writes that changed nothing relevant, misses writes that changed
something, and encodes a coincidence. Rejected.

**`DatabaseRegionObservation` instead.** Same hook, same silence.

## Revisit when

SQLite starts calling the update hook for `WITHOUT ROWID` tables, or GRDB grows another way to
detect changes to them.
