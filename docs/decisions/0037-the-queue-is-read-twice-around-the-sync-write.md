<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0037: The operation queue is read twice around a sync write, until the store can read it inside one

**Status:** Accepted, with a named replacement
**Date:** 2026-09-23
**Decided by:** WS-05, against the boundary ADR-0034 drew

## Context

[offline-queue.md](../architecture/offline-queue.md) specifies the conflict mechanism
exactly:

> Implemented as a read of `pendingOperation` inside the sync write transaction, not as a
> lock or a flag on the message row: one query, one truth, no state to leave behind when the
> app is killed at the wrong moment.

That is the right mechanism and WS-05 cannot write it. [ADR-0034](0034-the-store-returns-its-own-sequence.md)
made `MailStore.read` and `MailStore.write` internal so that no GRDB type crosses the store
boundary, which is correct and is what keeps `NCMailSync` from opening transactions of its
own. There is also no DAO that reads `pendingOperation`: WS-03 added the table and the
record type, WS-06 will add the queries, and WS-06 lands after WS-05.

So the choice is between shipping the ordering rule without the conflict rule, reaching
across into `NCMailStore` to add the DAO, or finding something correct inside the boundary.

## Decision

The queue is read **twice**, once either side of the write, and the second read repairs.

```
intents  = drainer.pendingIntents()          ← before the request
…
masked   = SyncConflicts.apply(page, intents) ← the user's fields win
store.upsert(envelopes: masked)
after    = drainer.pendingIntents()          ← after the write
repair   = rows whose intent changed in between
store.upsert(envelopes: repair)
```

This is correct for the race it covers, and the argument is short. WS-06 writes the local
row and the `pendingOperation` row in **one** transaction, so an operation is never visible
before the change it describes. An operation queued before the first read is masked. One
queued between the two reads is seen by the second and re-applied. One queued after the
second read wrote the row itself, after the sync's write, so the column already holds the
user's value.

It is also cheap. The second read costs one query per page, the repair costs an upsert of
however many rows actually changed, and on a drained queue — which is the common case,
because the drain runs first — both are skipped entirely: `intents` is empty and there is
nothing to compare.

## Consequences

Two queries where the document asks for one, and a reader of `SyncScheduler.write` has to
follow a two-step argument instead of reading `WHERE messageId IN (…)` inside a
transaction. The method's documentation carries the argument at the point where the question
occurs.

`OperationDraining.pendingIntents()` exists as a protocol method largely because of this. If
the store gains the DAO, that method can go and the protocol shrinks to `drain()`.

**The replacement is named.** WS-03 (or WS-06, whoever gets there first) adds

```swift
func upsert(envelopes: [EnvelopeWrite], preservingPendingOperationsFor accountId: Int64) async throws -> [Int64]
```

which does the masking inside the same transaction as the write. `SyncConflicts.apply` is a
pure function over `EnvelopeWrite` and `PendingIntent` and moves into `NCMailStore`
unchanged; `SyncScheduler.write` loses its second read and its repair pass. Until then this
stands, and `DrainOrderingTests.anIntentQueuedDuringTheWriteIsRepaired` is the test that has
to keep passing either way.

## Alternatives considered

**Add the DAO to `NCMailStore` from WS-05.** It is twenty lines and it is someone else's
file. `CLAUDE.md`: "Need a change elsewhere? Write it in your report. Do not reach across —
that is how two agents produce one conflict and two half-fixes."

**A flag on the message row saying "locally modified".** The document rules it out by name,
and it is right to: the flag is state to leave behind when the app is killed between setting
it and clearing it, which is precisely the case the queue exists to survive.

**Single read, before the write, and accept the race.** A window of one database write, and
the symptom is the one the ordering rule exists to prevent — the user watches their archive
undo itself — occurring rarely enough that nobody can reproduce it. A rare version of that
bug is worse than a common one.

**Hold a lock across the drain and the sync.** `SyncScheduler` already serialises them
within an account; the race is against the *user's* write, which comes from the main actor
and cannot be made to wait on a sync without making the UI wait on the network.
