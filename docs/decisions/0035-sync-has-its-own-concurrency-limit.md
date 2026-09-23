<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0035: The sync engine has its own concurrency limit and does not draw on the body budget

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-05, from WS-04's measured body latency

## Context

`MirrorBudget.shared` is a process-wide cap of four, added by WS-04 for rule 1 of
[local-mirror.md](../architecture/local-mirror.md#stage-2--bodies): two body fetches per
account, four across every account. The row it implements in
[networking.md](../architecture/networking.md#concurrency-budget) is **Body backfill**, and
that table has no row for incremental sync at all.

[sync-engine.md](../architecture/sync-engine.md) gives sync its own number instead: other
mirrored mailboxes run "10 minutes, round-robin, at most 3 at a time".

The obvious tidy move is to make the sync engine draw on `MirrorBudget.shared` so the
client never has more than four requests out at once, whatever they are. Two numbers
decide against it.

A body fetch is **1.37 s** on average, measured by WS-04 over 155 real messages on the live
server, with two earlier runs of identical code over the identical mailbox spread between
183 s and 1,498 s for the whole account. `GET /body` opens an IMAP connection, fetches,
parses and sanitises; a sync is a database read on the server.

A backfill runs for hours on a real account. So a shared budget means that for the whole of
the first mirror, every sync — including the one the user asked for by pressing `R` — queues
behind up to four IMAP fetches whose latency nobody controls.

## Decision

`SyncScheduler` bounds itself: `SyncConfiguration.mailboxConcurrency`, three by default,
halved for ten minutes after a 429 or a 503. It is a slot count inside the scheduler's own
`TaskGroup`, not a new shared object, and **no second process-wide budget is introduced**.

`MirrorBudget.shared` keeps meaning exactly what its documentation says: four *bodies*.

## Consequences

A client mirroring one account can have seven requests in flight: four bodies and three
syncs. That is the cost, and it is stated plainly rather than hidden — the honest
conversation with Nextcloud about what this client does to a server has to include it.

What it buys is that the promise in [user-stories.md](../product/user-stories.md) S-07 —
"new mail appears immediately on `R`" — holds during a backfill rather than only after one.
A sync is a handful of kilobytes against a warm database; four of them are not what makes a
server slow.

The throttle is the pressure valve. A server that says 429 halves both budgets, each in its
own subsystem, and the sync half is covered by `SyncScheduler.currentMailboxConcurrency`.

It also foreclosesa single dial for "requests this client may have outstanding". If that is
ever wanted, it belongs in `MailClient` where every request already passes, not in two
subsystems each holding half of it.

## Alternatives considered

**Draw sync from `MirrorBudget.shared`.** One number, one place, and a `R` that takes
seconds while the mirror fills. The budget's own documentation says "four bodies", so using
it for something else would have made that comment wrong as well.

**A second shared budget for sync.** Symmetrical, and it buys nothing: sync concurrency is
already per account and three accounts syncing three mailboxes each is nine cheap reads,
which is not the number that hurts a Nextcloud instance.

**Sync at concurrency 1.** Simplest of all, and a ten-mailbox account then takes ten round
trips in series to notice anything, which is the cadence table's "round-robin, at most three
at a time" written off for no gain.

## Revisit when

Someone measures a real server under several clients and finds that cheap reads matter
after all, or `MailClient` grows a global in-flight limit, at which point both subsystems
should hand their requests to it rather than counting for themselves.
