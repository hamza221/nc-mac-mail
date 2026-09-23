<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The sync engine

*Keeping a complete mirror in step with a server whose sync endpoint was designed for a
client that only knows one page of mail. Read [local-mirror.md](local-mirror.md) first.*

## The endpoint, and what it actually does

```http
POST /api/mailboxes/{id}/sync
{"ids": [12, 13, 14], "lastMessageTimestamp": 1736200000, "init": false, "sortOrder": "newest"}
```

```json
{"newMessages": [...], "changedMessages": [...], "vanishedMessages": [17, 19], "stats": {...}}
```

Four things about it are not obvious from the shape, and all four change the design. They
are all in `lib/Service/Sync/SyncService.php::getDatabaseSyncChanges` and
`lib/Db/MessageMapper.php::findNewIds`.

**1. `ids` is a window, not an inventory.** "New" means *not in `ids`, and newer than the
oldest `sent_at` among `ids`*. Send the ids of your ten most recent messages and you learn
about everything newer than the tenth. Send nothing and you get the entire mailbox back as
"new" (`findAllIds`).

**2. `changedMessages` is every id you sent that still exists.** There is no change
detection — the source carries a `TODO` saying so. Whatever you claim to know is re-sent to
you in full.

**3. `vanishedMessages` holds database ids, not IMAP UIDs**, despite the property being
called `vanishedMessageUids`. It is `array_diff(yourIds, stillExisting)`. So a message is
only reported vanished if you told the server you had it.

**4. `newMessages` only contains the newest message of each thread.** `findNewIds` joins
the table to itself on `thread_root_id` and keeps rows with no newer sibling. Two new
messages in one thread, and you are told about one.

Points 2 and 3 together mean the request and the response both scale with the window you
send. A full-mirror client that sent its whole known set would ship 50,000 ids up and
50,000 envelopes down, every two minutes, for nothing. Point 4 means that even if you did,
you would still be missing replies.

So: **a bounded window for liveness, a periodic full enumeration for completeness.**
That is [ADR-0015](../decisions/0015-bounded-sync-window.md), and the rest of this document
is its consequences.

## The three loops

### 1. Incremental sync — every couple of minutes

Per mailbox, with `ids` = the **most recent 250 message ids** the mirror holds for it
(`ORDER BY sentAt DESC LIMIT 250`; the constant is `SyncWindow.size`, tunable in one place).

```
POST /api/mailboxes/{id}/sync  {ids: [...250 ids...], init: false, sortOrder: "newest"}

newMessages      → upsert envelopes, enqueue bodies at the head of the backfill queue
changedMessages  → upsert envelopes; flags, tags and preview text are the point
vanishedMessages → delete locally (message, body, attachments, search rows)*
stats            → mailbox.unreadCount, totalCount
```

Then, because of trap 4, **the tail scan**: fetch page 1 of
`GET /api/messages?mailboxId=&view=singleton&limit=100` and walk pages until an entire page
is already known. Thread siblings that `newMessages` omitted appear here. In the steady
state this is one request that finds nothing new. The stop condition is a whole page with
nothing new in it, not the first id already known: the server orders by `sentAt` and one
recognised message says nothing about the next.

**The tail scan needs the account's sort order to be newest-first**, which is the server
default and the value of `GET /api/preferences/sort-order` when nobody has set it. A user
who chose oldest-first in the web client makes page 1 the *oldest* hundred and turns
`cursor` into a lower bound, so "page from the newest" cannot be expressed at all. On such
an account the scan is skipped and thread siblings wait for the deep reconcile, whose cursor
flips to `newest dateInt - 1` and which still enumerates correctly.
[ADR-0036](../decisions/0036-sort-order-decides-the-cursor.md).

A mailbox with no mirrored rows sends no window at all and is carried by the tail scan
alone. `{"ids": []}` is answered from `findAllIds` — the whole mailbox, unpaginated,
measured — so the bounded, paged request is the one to make.

\* `vanishedMessages` is scoped to the mailbox, measured: sending the inbox's sync an id
that lives in Sent Items reports it vanished. So a message moved in the web client is
"vanished from the source" here and "new" in the destination's own sync, under a **different**
`databaseId` — an IMAP move is a delete and an append. Deleting the local row is therefore
right, and the cost of a server-side move is one body re-fetched.

Cadence:

| Mailbox | Interval |
| --- | --- |
| Selected mailbox | 2 minutes |
| Inbox of every account | 2 minutes |
| Other mirrored mailboxes | 10 minutes, round-robin, at most 3 at a time |
| Any mailbox | Immediately on window focus, on `R`, and after the operation queue drains |

Off entirely while offline; resumed on reconnect with an immediate pass.

### 2. Deep reconcile — weekly, and on demand

Full enumeration per mailbox, exactly as stage 1 of the backfill, comparing ids — and
"exactly as stage 1" means with stage 1's cursor arithmetic, **`oldest dateInt + 1`**, not
the oldest `dateInt` itself. The comparison is strict and `dateInt` is not unique: the live
inbox has ids 44 and 45 both at 1778515439, and paging with the plain oldest value returns
44 and skips 45 with a 200 and no visible gap
([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md), trap 5 in
[../reference/api-payloads.md](../reference/api-payloads.md)). A reconcile written to find
missing mail that carried that blind spot would be worse than none: it would report the
mirror complete while the hole it exists to find stayed open. One function owns the
arithmetic, `SyncScheduler.nextCursor(after:sortOrder:)`, and both the tail scan and the
reconcile call it.

Comparing ids:

```
server ids (paginated, view=singleton)  vs  local ids
    in server, not local   → insert envelope, enqueue body
    in local, not server   → delete locally
    in both                → refresh the envelope (flags may have drifted)
```

This is the only thing that catches:

- a message deleted in the web client **outside** the 250-message window;
- a thread sibling that arrived while the app was closed and fell outside the window;
- anything lost to a crash between two pages of the original backfill;
- a mailbox that was re-created server-side with new ids.

It costs `ceil(n/100)` cheap requests per mailbox. Weekly per account, staggered, never
while the user is actively scrolling that mailbox, and always available as
**Settings › Storage › Check for missing messages**.

### 3. Mailbox-list sync — hourly and on demand

`GET /api/mailboxes?accountId=` re-reads the folder list: new folders appear, renamed ones
update, deleted ones are removed with their messages, and subscription changes are picked
up (which adds or removes mailboxes from the mirror —
[ADR-0007](../decisions/0007-subscribed-mailboxes-only.md)). `forceSync=true` only on
explicit user refresh; it makes the server re-read the folder list from IMAP.

`GET /api/accounts` runs alongside it, because `archiveMailboxId` and friends can change
and triage depends on them.

## Ordering and mutual exclusion

Per account, these never overlap:

1. **Drain the operation queue** ([offline-queue.md](offline-queue.md)). Always first: a
   sync that runs before the drain will happily overwrite the local row with the server
   state the queued action has not reached yet, and the user watches their archive undo
   itself.
2. **Incremental sync.**
3. **Backfill**, which yields to both.

`SyncScheduler` is an actor per account holding this order. Different accounts run
concurrently; within an account, the sequence is the sequence.

## Conflict rules, in one place

A sync response and a local row disagree. Who wins:

| Situation | Winner | Why |
| --- | --- | --- |
| No pending operation for that message | Server, always | The mirror is a copy; the server is the original |
| A pending operation sets field X | Local for X, server for everything else | The user's intent has not arrived yet; it is not wrong, it is in flight |
| Message vanished server-side, pending operation exists | Server | The message is gone; drop the operation, drop the row |
| Message moved server-side, local move queued | Server position after the drain resolves | The drain will fail with a 404/403 and reconcile; do not guess |
| Envelope differs, body already stored | Keep the body | Bodies are immutable in IMAP; only flags and tags change |

That last one matters for cost: a `changedMessages` entry never invalidates a stored body.
Re-fetching bodies on every sync would undo the entire point of the mirror. It needs no code
either: `EnvelopeWrite` has no `bodyState` column (ADR-0023), so no sync response can tell
the mirror it has lost a body.

The mechanism is a read of `pendingOperation`, and until `NCMailStore` exposes a DAO that
does it *inside* the sync write transaction, `SyncScheduler` reads the queue once either
side of the write and repairs anything that changed in between. That is correct for the
same reason the one-query version is — WS-06 writes the local row and the queue row in one
transaction — and it is temporary by design:
[ADR-0037](../decisions/0037-the-queue-is-read-twice-around-the-sync-write.md) names the DAO
that replaces it.

## Errors

| Response | Meaning | Action |
| --- | --- | --- |
| 200 | Fine | Apply |
| 202 + `fail` envelope | `IncompleteSyncException`; server still working | Retry in 30 s, up to 5 times, then next cycle. Not an error to the user |
| 400 + `{"status":"error"}` | `MailboxNotCachedException` and friends | Re-prime with `init: true`, then retry once |
| 403 | Delegation or account gone | Mark the account; do not delete local data without asking |
| 428 | Mailbox not cached (the `sync` route's own code) | Re-prime with `init: true` |
| 429 / 503 + `Retry-After` | Rate limited or overloaded | Honour the header; halve concurrency for 10 minutes |
| Timeout | Big mailbox, slow IMAP | Backoff, `syncFailureCount++`, move on. Three consecutive failures marks the mailbox in the UI |

A failing mailbox never blocks another, never clears what is mirrored, and never turns
into a modal.

## Instrumentation

Cheap counters, visible in a debug pane, because sync bugs are invisible without them:
requests per cycle, envelopes written, bodies enqueued, bytes down, backoff state, last
error per mailbox, and time since last successful sync per mailbox. They are `SyncMetrics`
and `MailboxSyncMetrics`, read from `SyncScheduler.metrics`; WS-14 asserts on them in the
fake-transport tests.

One of them is narrower than its name. **`envelopeBytesDown` counts the `rawJSON` each
envelope carries, not the transfer size**, because `MailClient` hands back a decoded value
and never the response length. It is the payload and within a few per cent of the body of
the response. A byte-accurate figure needs `NCMailNet` to report it, which is a request in
WS-05's report.
