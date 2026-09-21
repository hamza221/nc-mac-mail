# WS-05 — Incremental sync, tail scan, deep reconcile

**Wave 2, after WS-04. Size: L.**

## Goal

Keep a complete mirror complete, cheaply, against a sync endpoint whose semantics are not
what its parameter names suggest.

## Before you start

- [../../architecture/sync-engine.md](../../architecture/sync-engine.md) — **all of it**
- [../../decisions/0015-bounded-sync-window.md](../../decisions/0015-bounded-sync-window.md)
- [../../reference/api-payloads.md](../../reference/api-payloads.md) — traps 2, 3 and 4
- [../../product/user-stories.md](../../product/user-stories.md) — S-07

Understand the four traps before writing a line. Three of them produce a mirror that is
quietly wrong rather than visibly broken, which is the expensive kind.

## You own

`Packages/NCMailSync/Sources/NCMailSync/Sync/**`

## Build

```swift
public actor SyncScheduler {
    public init(store: MailStore, client: MailClient, accountId: Int64, drainer: OperationDrainer?)
    public func start() async
    public func syncNow(mailboxId: Int64?) async     // R, or window focus
    public func deepReconcile(mailboxId: Int64?) async
    public func stop() async
}
```

**Incremental**, per mailbox:

1. `ids` = the 250 most recent local message ids (`SyncWindow.size`, one constant, one
   place).
2. `POST /api/mailboxes/{id}/sync` with `{ids, init: false, sortOrder: <account preference>}`.
3. Apply: `newMessages` upsert and enqueue bodies at the head; `changedMessages` upsert
   (flags, tags, preview — **never** invalidate a stored body); `vanishedMessages` delete
   locally, including body, attachments and FTS row; `stats` update the counts.
4. **Tail scan**: page `GET /api/messages?view=singleton&limit=100` from newest until an
   entire page is already known. This is what catches the thread siblings `newMessages`
   omits. In the steady state it is one request finding nothing.

Cadence: selected mailbox and every inbox every 2 minutes; other mirrored mailboxes every
10, round-robin, at most three concurrently; immediately on focus, on `R`, and after the
operation queue drains. Nothing while offline.

**Deep reconcile:** a full `view=singleton` enumeration compared against local ids —
insert missing, delete gone, refresh the rest. Weekly per account, staggered, never while
the user is scrolling that mailbox, always available from Settings.

**Mailbox list:** `GET /api/mailboxes` hourly and on demand; `GET /api/accounts` alongside
it, because `archiveMailboxId` can change under triage. `forceSync=true` only on explicit
user refresh.

**Ordering — the single most important rule in the app.** Per account: drain the operation
queue, **then** sync, **then** let backfill have what is left. A sync that runs before the
drain overwrites a not-yet-sent change, and the user watches their archive undo itself.

**Conflicts** follow the table in the sync document. The mechanism is a read of
`pendingOperation` inside the sync write transaction — one query, one truth, no flag on the
message row to leave behind when the app is killed at the wrong moment.

**Instrumentation**: requests per cycle, envelopes written, bodies enqueued, bytes down,
backoff state, last error and last success per mailbox. WS-14 asserts on these.

## Acceptance

Against a real account:

- New mail appears within the interval, and immediately on `R`.
- Read, star, move and delete performed in the web client all appear here next cycle.
- A reply to an existing thread appears — this is the tail-scan test, and it is the one
  that fails if trap 3 was not handled.
- Deleting a message in the web client from **outside** the 250-window does not disappear
  locally until a deep reconcile, and then it does. Demonstrate both halves.
- A mailbox that returns 428 is re-primed and syncs without user-visible failure.
- One failing mailbox does not stop the others and does not clear what is mirrored.
- Sync stops entirely while offline; resumes with an immediate pass on reconnect.
- Steady-state traffic is constant per mailbox regardless of mirror size — measure it.

Fake-transport tests for: vanished handling, siblings, re-created mailbox ids, a
reconcile finding a hole, and a sync arriving mid-drain that must not clobber a pending
intent.

## Out of scope

The initial backfill (WS-04). The drainer itself (WS-06 — you call it; if it is not merged
yet, take it as an optional dependency and ship the ordering rule in place).

## Report

Additionally: measured steady-state requests and bytes per hour for a 50,000-message
account, and whether `SyncWindow.size = 250` held up or wants changing — with the number
that convinced you.
