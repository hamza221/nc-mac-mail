<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The offline mutation queue

*Every change the user makes is written locally and replayed to the server. This is how.
Decision record: [ADR-0005](../decisions/0005-offline-mutation-queue.md).*

## The rule

**A triage action is one local transaction, and a promise to tell the server.**

```swift
try await store.enqueue(rows, applying: effects)  // one transaction, both halves
drainer.wake()
```

Inside that one call, per row: the local change, then the `pendingOperation` insert. The
call is `enqueue` rather than a `store.write { … }` block because `MailStore.write` is
internal ([ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md)), so the
transaction is opened by a method on `MailStore` —
`Queries/MailStore+Operations.swift`, added by
[ADR-0045](../decisions/0045-the-store-grows-the-queue-dao-and-the-readers.md). The shape of
the guarantee is unchanged.

A multi-message action is one transaction and several rows — archiving ten messages is ten
requests, because the server has no batch route, but the ten local changes land together or
not at all.

Both halves commit or neither does. There is no window in which the screen says archived
and nothing remembers to tell the server, and none in which an operation is queued for a
change the user cannot see.

Online or offline changes nothing about that code path. Offline is not a mode; it is the
drainer having nowhere to send things yet.

## Operations

| Kind | Local effect | Request |
| --- | --- | --- |
| `setFlags` | flag columns on `message` | `PUT /api/messages/{id}/flags` `{"flags":{"seen":true}}` |
| `move` | `message.mailboxId` | `POST /api/messages/{id}/move` `{"destFolderId":N}` |
| `delete` | move to trash, or delete the row when already in trash | `DELETE /api/messages/{id}` |
| `junk` | `isJunk`, then move to `junkMailboxId` | flags, then move — two operations, in order |
| `moveThread` | every message of the thread | `POST /api/thread/{id}` `{"destMailboxId":N}` |
| `deleteThread` | every message of the thread | `DELETE /api/thread/{id}` |
| `markThread` | flags across the thread | one `setFlags` per message |

Note the parameter names: `destFolderId` for a message, `destMailboxId` for a thread. That
inconsistency is upstream's, it is real, and it has already cost someone an afternoon —
see [../reference/api-payloads.md](../reference/api-payloads.md).

Archive is not an operation kind. It is `move` to the account's archive mailbox, resolved at
queue time from the account that owns the message, never from the selected account.

**`account.archiveMailboxId` is not that id.** It and `trashMailboxId`, `junkMailboxId` and
their siblings hold the *server's* numbers, copied straight out of the accounts payload, and
unlike every other server-numbered value in the mirror they are not spelled `remoteId`
(ADR-0033). Writing one into `message.mailboxId` files the message under whichever local
mailbox happens to share that number. `MutationQueue.localMailboxId(for:accountId:)` does the
lookup, and it answers nil for an account with no archive folder configured — which a live
server commonly has not.

## The payload is intent, not a diff

`payloadJSON` stores the **absolute desired state** of the fields the action touches:
`{"seen": true}`, not `{"toggle": "seen"}`. Three reasons:

- Replaying it twice is harmless, so a retry after an ambiguous timeout is safe.
- Two operations on the same message and field collapse to the later one.
- The conflict rule ("local wins for the fields the operation sets") has something
  concrete to name.

Two more keys share the column, and both are implementation rather than intent.
`remoteId` is the server's id for the message the request names, copied in at queue time
because the local row may be gone by the time the drain runs — a `delete` of a message
already in trash erases it on the spot. `before` is the pre-action state of exactly the
fields the operation sets, which is what makes **Discard** able to revert: nothing else in
the row remembers it, since `baseSyncedAt` records when the server last spoke and not what
the flag used to be.

## Draining

`OperationDrainer` is an actor per account. One operation in flight at a time per account,
in `id` order — mail actions are causally ordered (star then move then delete) and
parallelising them buys milliseconds while risking a wrong final state.

```
wake ─▶ any rows where state='pending' and (nextAttemptAt is null or nextAttemptAt <= now)?
        │
        ├─ no  ─▶ sleep until woken by an action, a reconnect, or nextAttemptAt
        │
        └─ yes ─▶ collapse ─▶ mark inFlight ─▶ request
                                                │
             2xx ────────────▶ delete row; apply the response envelope if it returned one
             404 / 410 ──────▶ delete row; delete the local message (it is gone)
             403 ────────────▶ delete row; refresh the account; surface once
             409 / 412 ──────▶ delete row; force a sync of that mailbox; let the server win
             429 / 503 ──────▶ honour Retry-After, requeue, do not count as a failure
             5xx / offline ──▶ attempts++, nextAttemptAt = now + backoff, state=pending
```

Backoff: 2, 8, 30, 120, 600 seconds, then every 10 minutes. After 5 attempts the operation
also becomes **visible** (below); it keeps retrying regardless, because the usual cause is
a laptop that has been shut since Friday.

**Collapsing** runs once at the start of each pass, over the account's whole queue:

- consecutive `setFlags` on the same message merge (later keys win);
- a `move` followed by a `move` of the same message keeps the last destination;
- anything followed by `delete` on the same message collapses to the `delete`;
- operations for different messages never collapse, and order across messages is preserved;
- a thread operation never collapses into a message operation for one of its members.

This document originally asked for the collapse before *each* request. Re-reading and
re-collapsing the whole queue per request made a thousand queued operations take **52.4 s**
against a transport that answers instantly; collapsing once per pass takes **0.45-0.8 s** for
the same thousand, and queueing them in one transaction costs **0.27-0.41 s** (five runs,
`OperationDrainScaleTests`). The only thing the change gives up is folding an operation
queued *during* the pass into one already being sent — and that operation wakes the drainer,
so it goes out in the pass that follows.

Those are the queue's own costs, and they are not what a real drain of a thousand operations
takes. The server has no batch route and the drain is deliberately serial, so it is a
thousand sequential round trips; the local work is under a millisecond each and everything
else is the network. **That number has not been measured against a live server** — the test
instance was down for the whole of WS-06 — so it stays unstated here rather than guessed.
What the measurement does establish is that the queue itself is not the cost, and that the
drain runs entirely behind the UI: the list was already correct when the user acted.

An operation that fails five times also becomes **visible** as one entry, not five: the fold
is what the popover lists and what **Discard** reverts, so star-unstar-star is one line and
one revert rather than three.

## Conflicts

The full table is in [sync-engine.md](sync-engine.md#conflict-rules-in-one-place). The
rule the drainer is responsible for:

> While an operation is pending for a message, a sync may not overwrite the fields that
> operation sets.

Implemented as a read of `pendingOperation`, not as a lock or a flag on the message row: one
query, one truth, no state to leave behind when the app is killed at the wrong moment. The
read wants to be inside the sync write transaction and is not yet — `SyncScheduler` reads it
either side of the write and repairs, because the write it wants to read inside of is
`upsert(envelopes:)` and there is still no masking variant of that;
[ADR-0037](../decisions/0037-the-queue-is-read-twice-around-the-sync-write.md) has the
argument and names the method. `OperationDrainer.pendingIntents()` is what it reads: the collapsed final state per
message, so star-unstar-star masks with `flagged: true` rather than with three intents.

The drain runs **before** sync for exactly this reason
([sync-engine.md](sync-engine.md#ordering-and-mutual-exclusion)). If the queue is empty
when sync starts, there is no conflict to resolve at all, which is the common case.

## Surfacing failure

Silence is the failure mode to avoid. The user archived something; they are entitled to
know if it did not happen.

- **Under 5 attempts:** nothing visible. Retrying is normal.
- **5 or more, or a permanent rejection:** a single indicator in the sidebar footer —
  "2 actions waiting" — opening a popover that lists them with what failed and offers
  **Retry now** and **Discard**. Discard reverts the local change too, so the screen and
  the server agree again.
- **Never** a modal, never a per-message error badge, never a toast per failure. A flaky
  connection during a triage pass must not produce forty alerts.

The count is that query:

```sql
SELECT count(*) FROM pendingOperation WHERE state != 'inFlight' AND attempts >= 5;
```

`OperationDrainer.pendingCount` publishes it as an `AsyncStream<PendingSummary>` rather than
as a store observation, and republishes after every change: `MailStore.pendingOperations`
is a read, and the drainer already holds the collapsed list, so re-reading the queue after
every operation would buy nothing. `AppStatus.pendingFailures` is `PendingSummary.failing`. Subscribing yields the
current summary immediately, so a view drawn late is not blank until something changes.

**Discard has one exception.** A `delete` of a message that was already in trash erased the
row, and there is nothing left to restore. Discarding it drops the operation and the next
sync brings the message back, because the server was never told.

## Sign-out and pending work

Signing out with a non-empty queue asks: **Send now**, **Discard**, or **Cancel**. Data
loss without a question is not acceptable, and neither is an app that cannot be signed out
because a server is down.

WS-12 asks `OperationDrainer.summary().queued` whether to ask at all, and answers with
`drain()` or `discardAll()`. `discardAll` reverts newest first, so a message moved twice ends
up where it started rather than where the first move left it.

## Testing it

WS-06 owns these; WS-14 provides the fake transport. Every one of them is a unit test, no
server required:

- action while offline → row present, list updated, queue depth 1;
- quit and relaunch with a queued operation → still queued, still applied locally;
- reconnect → drains in order, queue empties, local state unchanged;
- 404 on drain → local message removed, no error shown;
- 500 five times → visible, still retrying, `Retry now` works;
- star then unstar then star, offline → one operation reaching the server, final state
  correct;
- sync arriving mid-queue with contradictory flags → local intent survives for the queued
  field, server wins for the rest;
- discard → local revert matches the pre-action state exactly.
