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
try await store.write { db in
    try applyLocally(db)                 // the list updates from this
    try PendingOperation(...).insert(db) // the drainer picks this up
}
drainer.wake()
```

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

Archive is not an operation kind. It is `move` to `account.archiveMailboxId`, resolved at
queue time from the account that owns the message, never from the selected account.

## The payload is intent, not a diff

`payloadJSON` stores the **absolute desired state** of the fields the action touches:
`{"seen": true}`, not `{"toggle": "seen"}`. Three reasons:

- Replaying it twice is harmless, so a retry after an ambiguous timeout is safe.
- Two operations on the same message and field collapse to the later one.
- The conflict rule ("local wins for the fields the operation sets") has something
  concrete to name.

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

**Collapsing** runs before each request, inside the read transaction that picks the work:

- consecutive `setFlags` on the same message merge (later keys win);
- a `move` followed by a `move` of the same message keeps the last destination;
- anything followed by `delete` on the same message collapses to the `delete`;
- operations for different messages never collapse, and order across messages is preserved.

## Conflicts

The full table is in [sync-engine.md](sync-engine.md#conflict-rules-in-one-place). The
rule the drainer is responsible for:

> While an operation is pending for a message, a sync may not overwrite the fields that
> operation sets.

Implemented as a read of `pendingOperation` inside the sync write transaction, not as a
lock or a flag on the message row: one query, one truth, no state to leave behind when the
app is killed at the wrong moment.

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

The count comes from the same database the rest of the UI observes:

```sql
SELECT count(*) FROM pendingOperation WHERE state != 'inFlight' AND attempts >= 5;
```

## Sign-out and pending work

Signing out with a non-empty queue asks: **Send now**, **Discard**, or **Cancel**. Data
loss without a question is not acceptable, and neither is an app that cannot be signed out
because a server is down.

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
