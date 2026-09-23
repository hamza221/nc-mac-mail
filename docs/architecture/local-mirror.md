<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The local mirror

*What is stored, how it gets there, how it survives a quit, and who is allowed to delete
it. The schema is [../reference/schema.sql](../reference/schema.sql); this is the
behaviour around it.*

Decision record: [ADR-0003](../decisions/0003-local-first-full-mirror.md). Read that first
if you are wondering why a client does this at all when the server already caches IMAP.

## What "mirror" means here

Every message in every **subscribed** mailbox of every account, envelope and body, stored
locally, kept indefinitely, and preferred over the server for every read.

It is not a cache in the usual sense: nothing expires, nothing is evicted under pressure,
and a cache miss is a bug in the backfill rather than a normal event. The only things that
remove data are the user, a sign-out, and a message that no longer exists on the server.

What is **not** stored: attachment payloads (fetched on demand; inline images are kept
once fetched so a message read offline still shows its own pictures), raw MIME
([ADR-0009](../decisions/0009-sanitised-html-not-raw-mime.md)), and anything from
unsubscribed mailboxes beyond what the user opened
([ADR-0007](../decisions/0007-subscribed-mailboxes-only.md)).

## Where it lives

```
~/Library/Containers/com.nextcloud.mail.macos/Data/Library/Application Support/
    NextcloudMail/
        mirror.sqlite          the database
        mirror.sqlite-wal
        mirror.sqlite-shm
```

One database for all accounts. Cross-account search and a future unified inbox are
single-statement features that way, and the alternative — a file per account — buys
isolation we have no use for. Per-account deletion is `DELETE FROM account WHERE id = ?`
plus `VACUUM`, which the cascade rules in the schema make complete.

At-rest protection is the sandbox container plus FileVault, and the threat model is
written down honestly in [security.md](security.md) and
[ADR-0006](../decisions/0006-data-at-rest.md).

## The two-stage backfill

Stage 1 makes the app usable. Stage 2 makes it complete. They run per account, and
accounts run in parallel with each other.

Measured on the live account from an empty database, reading the database the way a view's
`ValueObservation` does: the sidebar has its mailboxes **0.86 s** after sign-in, and the
inbox has more than fifty rows at **3.9 s**, at which point five mailboxes are still being
enumerated and not one body has been downloaded. That gap is the whole design.

### Stage 0 — priming (per mailbox, cheap, mandatory)

The server keeps its own IMAP cache and refuses to enumerate a mailbox it has not cached:
`GET /api/messages` on an uncached mailbox throws `MailboxNotCachedException`, which the
error middleware turns into **400** with a `{"status":"error"}` body, and
`POST /api/mailboxes/{id}/sync` without `init` returns **428 Precondition Required**
(`lib/Controller/MailboxesController.php:186`).

So every mailbox starts with:

```http
POST /api/mailboxes/{databaseId}/sync
{"ids": [], "init": true}
```

- **200** — primed. `lastPrimedAt` is set. The response also carries envelopes, free:
  with an empty `ids` the server answers from `findAllIds` rather than the thread-head
  self-join, so none of them is a thread head standing in for its replies. Measured by WS-04
  against the live server: mailbox 5, 95 messages, 95 envelopes back. They are stored, and
  **the cursor is not advanced from them** — stage 1 still reads its own first page, because
  "all" was measured on 95 messages and nothing promises it at 50,000
  ([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)).
- **202 Accepted** with a `fail` envelope — `IncompleteSyncException`: the server is still
  working. Retry with backoff; do not treat as an error.
- **5xx / timeout** — a large mailbox on a slow IMAP server can take a while. Retry with
  backoff, mark `lastSyncError`, and move to the next mailbox. One slow mailbox must never
  block the account.

### Stage 1 — envelopes

Per mailbox, oldest-ward, page by page:

```http
GET /api/messages?mailboxId={id}&view=singleton&limit=100&cursor={oldest dateInt so far}
```

- `view=singleton` is mandatory. The threaded view returns only the newest message of each
  thread, so enumerating with it silently skips every reply — see
  [ADR-0014](../decisions/0014-singleton-enumeration.md) and the trap list in
  [../reference/api-payloads.md](../reference/api-payloads.md).
- `limit` is clamped server-side to 1…100 (`lib/Controller/MessagesController.php:index`).
  Use 100.
- `cursor` is the `dateInt` of the last (oldest) envelope received. Pass it to get the
  next page. It is **exclusive**, verified by WS-04 against the live server: a full walk of
  the 95-message inbox at `limit=10` returned 10 pages and 95 distinct ids with no
  duplicate at any boundary.
- Write the page, then the new `mailbox.envelopeCursor`, **in that order**. Two
  transactions, not one: `MailStore.upsert(envelopes:)` owns the page write including the
  address rewrite and the FTS row, and its internals are not reachable from `NCMailSync`.
  The ordering is what matters — a crash in between re-fetches one page whose upserts land
  identically, while the reverse order advances past messages that were never written and
  nothing downstream would ever look for them
  ([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)).
- A page shorter than `limit` ends the mailbox: set `envelopesComplete = 1`.

**Duplicate `dateInt` values at a page boundary lose a message**, and this document used
to claim the opposite. The cursor is strictly exclusive, measured on the live server: with
`cursor=1789590490` the message whose `dateInt` is exactly 1789590490 does not come back.
So if two messages share a `dateInt` and the page ends between them, the second is never
enumerated — the live inbox has such a pair, ids 44 and 45 at 1778515439, and the algorithm
as written dropped id 45.

The fix is one character: send **`oldest dateInt + 1`**, not `oldest dateInt`. The next page
then starts with the boundary message again, whose upsert finds the existing row through
`idxMessageAccountRemote` and changes nothing, and costs at most one duplicated row per
page. Verified against the same pair:
`cursor=1778515440` returns both 44 and 45. WS-04 does this;
[ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md) records it, and
`mailbox.envelopeCursor` therefore holds the exclusive upper bound for the *next* page
rather than the oldest `dateInt` seen.

The deep reconcile in [sync-engine.md](sync-engine.md) is still what guarantees
completeness, and WS-05 uses the same `+ 1` when it enumerates —
`SyncScheduler.nextCursor(after:sortOrder:)`, called by both the tail scan and the
reconcile.

**Both directions of that `+ 1` exist, and stage 1 only implements one of them.** The sort
order that decides which way `cursor` points is a server-side *preference*, not a
parameter: with `sort-order` set to `oldest`, page one of `GET /messages` is the oldest
hundred and `cursor` becomes an exclusive lower bound, measured by WS-05 on the live server
and written up in [ADR-0036](../decisions/0036-sort-order-decides-the-cursor.md). Stage 1 as
written above starts with no cursor and always sends `oldest dateInt + 1`, so on an
oldest-first account it advances by one row per page — 50,000 requests where 500 would do,
with the "cursor did not advance" guard never firing because the cursor does advance. The
fix is one call to `SyncScheduler.nextCursor(after:sortOrder:)` in `enumerate(_:)`; WS-05
does not own `Mirror/**` and has left it as a request rather than changing it.

Cost for a 50,000-message mailbox: 500 requests, each a database read on the server, a few
minutes. This is the fast stage.

### Stage 2 — bodies

Every message with `bodyState = 'missing'` is a work item. The scheduler picks them
**newest first, across all mailboxes of the account**, because recency is what people open.

Per message, two requests:

```http
GET /api/messages/{id}/body                  → envelope + attachments + smime + dkim + body
GET /api/messages/{id}/html?plain=true       → the sanitised HTML fragment, no wrapper
```

The second is skipped when `hasHtmlBody` is false: a plain-text message's body is already
in the first response.

`?plain=true` matters. Without it the server wraps the HTML in a document with an iframe
resizer script and a nonce (`lib/Http/HtmlResponse.php`), which is machinery for an
`<iframe>` in a browser. We supply our own document shell — see [rendering.md](rendering.md).

Then, in one transaction: `messageBody`, the `attachment` rows, the `messageSearch` row,
`message.bodyState = 'present'`, and the byte count for the storage panel.

**This stage is expensive on the server.** `GET /body` opens an IMAP connection, fetches
the message, parses and sanitises it (`MessagesController::getBody`). It is not a database
read. Four rules follow, and they are not optional:

1. **Bounded concurrency.** Two in-flight body fetches per account, four in total,
   configurable downward. Never per-mailbox concurrency on top of that.
2. **Yield to the user.** Opening a message inserts it at the head of the queue and pauses
   one worker; interactive latency beats throughput every time.
3. **Back off on pressure.** 429 or 503 → exponential backoff honouring `Retry-After`,
   and halve the concurrency for the next ten minutes.
4. **Stop when the machine is not ours to use.** Low Power Mode, or an `NWPath` that is
   `isExpensive` or `isConstrained`, pauses stage 2 (never stage 1, which is cheap and
   makes the app usable). Say so in the progress UI rather than looking stalled.

A body that fails three times gets `bodyState = 'failed'` and is retried on the next deep
reconcile, not in a tight loop. A message whose body cannot be fetched at all (a server
that lost the IMAP message between the envelope and the body) is caught by reconcile and
its envelope removed.

### Progress

Progress is computed, not counted into a variable:

```sql
SELECT
  (SELECT count(*) FROM message WHERE accountId = ?)                              AS total,
  (SELECT count(*) FROM message WHERE accountId = ? AND bodyState = 'present')    AS done,
  (SELECT count(*) FROM mailbox WHERE accountId = ? AND isMirrored AND NOT envelopesComplete) AS mailboxesLeft;
```

Which means it is correct after a crash, correct after a restore, and needs no bookkeeping
of its own. Stage 1 reports mailboxes remaining, stage 2 reports messages. Never a
percentage of a total the app does not know yet.

## The state machine

Per mailbox, in `mailbox.isMirrored / envelopesComplete / bodiesComplete`, with the
account-level rollup in `account.mirrorState`:

```
        ┌──────────┐  subscribed
        │   idle   │─────────────┐
        └──────────┘             ▼
                           ┌──────────┐  428/202
                           │ priming  │◀────────┐
                           └────┬─────┘         │
                          200   │               │ retry w/ backoff
                                ▼               │
                         ┌─────────────┐        │
                    ┌───▶│  envelopes  │────────┘
       resume after │    └──────┬──────┘
       quit/offline │      short page
                    │           ▼
                    │    ┌─────────────┐
                    └────│   bodies    │  (account-wide queue, newest first)
                         └──────┬──────┘
                          queue empty
                                ▼
                         ┌─────────────┐   new mail     ┌──────────────┐
                         │  complete   │───────────────▶│ incremental  │
                         └─────────────┘                │    sync      │
                                ▲                       └──────┬───────┘
                                └──────────────────────────────┘
```

`paused` and `failed` are orthogonal flags rather than states: a paused mirror resumes
into whatever stage it was in, and a failed mailbox keeps everything it already has.

Every transition is a database write. Nothing about the mirror's progress lives in memory,
which is what makes "quit mid-backfill and relaunch" a non-event.

## Reading through the mirror

Every read goes to the database. The rules the store enforces:

| Read | Source | When it is not there yet |
| --- | --- | --- |
| Mailbox list | `mailbox` | Mirror is priming; sidebar shows the accounts it has |
| Message list | `message`, windowed | Row count grows as stage 1 runs; no spinner, the list just fills |
| Message body | `messageBody` | Enqueue at head, show a lightweight "fetching" state on that one message |
| Thread siblings | `message` grouped by `threadRootId` | Same as the list |
| Attachment payload | Network on demand | Normal download progress; inline images are stored after the first fetch |
| Avatar | `avatar` | Fetch once, store, including a `missing` marker so a 404 is not re-asked every launch |
| Search | `messageSearch` | Reports how much of the account is indexed |

The one place the app deliberately blocks on the network is an attachment download the
user explicitly asked for. Everything else is a database read.

## Storage accounting and the user's controls

[ADR-0008](../decisions/0008-no-automatic-eviction.md): there is no automatic eviction.
What there is instead:

- **Settings › Storage** lists each account: local size, message count, mirror state,
  backfill progress.
- **Remove local copies** deletes `messageBody`, `attachment.data` and the search rows for
  that account, keeps envelopes, `VACUUM`s, and leaves the app fully working — bodies
  re-fetch when opened, and the backfill can be restarted.
- **Re-download** clears the same and resets `bodyState` to `missing`, which restarts
  stage 2. Used when the server's sanitiser changes and old HTML should be refreshed —
  that is what `messageBody.sanitiserGeneration` is for.
- **Pause backfill** is a `meta` key, and it persists.

Sizes come from `sum(byteSize)` plus the file size on disk; do not shell out to `du`.

Every destructive control says, in the confirmation, that it removes **local copies only**
and does not touch the server. That sentence is not decoration. A user who believes
"remove" might delete their mail will never press it, and the control exists to be pressed.

## Sizing, so nobody is surprised

We store sanitised HTML rather than raw MIME, and no attachment payloads, which is what
keeps these numbers as low as they are — attachments are most of a mailbox's bytes.

Two measurements, taken differently, and both worth having.

**One recorded body, exactly.** `PerformanceTests.sizingOfAMirrorOnDisk` (WS-03) writes a
real SQLite file, `VACUUM`s it and counts pages rather than the file, so a leftover
write-ahead log neither flatters nor inflates it. Run it with
`NCMAIL_SIZING=1 swift test --filter sizingOfAMirrorOnDisk`.

**A whole account, averaged.** `MirrorLiveMeasurementTests.mirrorsAWholeAccount` (WS-04)
mirrors a live server to a file and divides. Run it with

```
NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=… NCMAIL_LIVE_PASSWORD=… \
NCMAIL_LIVE_KEEP=1 swift test --filter mirrorsAWholeAccount
```

and ask `sqlite3 … 'SELECT name, sum(pgsize) FROM dbstat GROUP BY name'` where the bytes
went. The account is 155 messages across five subscribed mailboxes — small, and the only
real corpus this repository has. **It is not the 5,000-message account the WS-04 brief asks
for; nobody has run this against one yet.**

| Per message | One marketing email (WS-03) | Averaged over 155 real messages (WS-04) |
| --- | --- | --- |
| Envelope, addresses and every index on them | 593 bytes | **2.3 KB** |
| Body row | 34.8 KB, from 30.1 KB of HTML | **31.5 KB**, from 28.7 KB of HTML |
| Its search index, stored copy included | 7.1 KB, 24% of the body | **6.3 KB**, 22% of the body |
| All in | 43.6 KB | **41.0 KB** |

The envelope row is the surprise, and it is four times what the synthetic measurement said.
`MailStoreFixtures` writes `rawJSON = "{}"`; a real envelope's `rawJSON` is about 1 KB of
its own, so the column ADR-0020 added is most of an envelope's cost. It is still the right
trade at 2.3 KB.

Multiplying the averaged costs, which is arithmetic and not a measurement:

| Mailbox | Envelopes | Bodies | Search index | Total |
| --- | --- | --- | --- | --- |
| 10,000 messages | 23 MB | 315 MB | 63 MB | **401 MB** |
| 50,000 messages | 115 MB | 1.6 GB | 315 MB | **2.0 GB** |
| 250,000 messages | 575 MB | 7.9 GB | 1.6 GB | **10.1 GB** |

Three findings from taking the measurements, all already fixed in the code:

- **Every message's text was on disk twice.** `messageBody.rawJSON` held the `/body`
  response including its `body` field, which is the same text as the `html` column:
  4,447,526 bytes of 4,785,035, and 41% of the whole file. The mapping now drops that one
  key ([ADR-0032](../decisions/0032-body-text-is-not-kept-twice.md)) and the same account
  went from 70.8 KB per message to 41.0 KB. The rows above are after the fix.
- The search index is 22–24% of the body, which is what
  [ADR-0011](../decisions/0011-fts5-standalone-index.md) predicted — but only after the
  indexer learned to drop the contents of `<style>`. The server's sanitiser keeps style
  blocks, a marketing email is mostly CSS, and indexing it made the index 2.2× the body
  instead of a quarter of it.
- `messageBody` costs about 10% more than the text in it. That is SQLite overflow pages,
  which is what a 30 KB text value costs on a 4 KB page, and there is nothing to do about
  it short of compressing bodies.

## Failure modes and what happens

| Failure | Behaviour |
| --- | --- |
| Network disappears mid-backfill | Pause, keep everything, resume on reconnect. No error banner |
| App killed mid-page | The page's transaction either committed or did not; the cursor is consistent either way |
| Database file corrupt | Detected at open; offer to rebuild (delete + full re-mirror), never fail to launch |
| Disk full | Pause the backfill, surface it once in the storage panel with the number needed |
| Server drops a message between stage 1 and stage 2 | `/body` 404s → envelope removed on the next reconcile |
| Server's sanitiser changes | Bump `sanitiserGeneration`; bodies below it re-fetch lazily on open |
| Account removed server-side | Sync gets 403/404 on that account → mark it and ask the user before deleting local data |
| Clock skew between server and client | Nothing depends on the client's clock; cursors are server `dateInt` values |

## What this costs the server, in one place

For an honest conversation with Nextcloud about whether this is acceptable, and for the
first thing to measure:

- Stage 1: `ceil(messages / 100)` cheap database reads per mailbox, once, plus one
  `POST /sync {"ids": [], "init": true}` per mailbox to prime.
- Stage 2: one IMAP fetch + parse + sanitise per message, once, at a maximum of four
  concurrent per client. Plus one `/html?plain=true` per message that has an HTML part —
  cheap by comparison, since the server has the parsed message by then.
- Steady state: one `POST /sync` per mailbox per interval, plus one `/body` per message
  actually opened that was not already mirrored (which, once backfill completes, is none).

Measured, on a first full mirror of the live account (155 messages, five subscribed
mailboxes, WS-04):

| | Measured |
| --- | --- |
| Requests, whole backfill | **277** — 2 bootstrap, 5 primes, 5 pages, 155 `/body`, 110 `/html` |
| Requests per message | **1.71** (110 of 155 messages had an HTML part; 45 were plain text and cost one request) |
| Wall clock | **213 s**, at two concurrent body fetches — 1.37 s per message |

The wall clock is the server's, not the client's: the mirror spends it waiting. Two earlier
runs of the identical code over the identical mailbox took 183 s and 1,498 s, and the
eight-fold spread is IMAP fetch latency on a cold cache. It is the strongest argument in
this document for the bulk-body endpoint in
[../feedback/server-findings.md](../feedback/server-findings.md): the request count is
modest and the per-request cost is not, and only the server can fix the second.

The steady state is **cheaper** than the web client, which re-fetches bodies it has already
shown whenever its 600-second server-side cache expires. The one-time backfill is the
whole cost, and it is bounded, resumable and pausable. If Nextcloud wants a server-side
guard, the honest ask is a bulk-body endpoint — noted in
[../feedback/server-findings.md](../feedback/server-findings.md).
