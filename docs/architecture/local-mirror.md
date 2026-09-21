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

- **200** — primed. `lastPrimedAt` is set. The response also carries the first full
  envelope set for the mailbox (`findAllIds` when `ids` is empty), so stage 1 can skip its
  first page.
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
  next page.
- Write the page and the new `mailbox.envelopeCursor` **in one transaction**. A crash
  between the two is the only way to get a gap, and there is no between.
- A page shorter than `limit` ends the mailbox: set `envelopesComplete = 1`.

Duplicate `dateInt` values at a page boundary can cause a message to repeat across pages;
upserts by primary key make that harmless. They cannot cause a skip, because the cursor is
inclusive-exclusive on a value that repeats — but the deep reconcile in
[sync-engine.md](sync-engine.md) is what actually guarantees completeness, and it exists
partly for this.

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

Measured against typical corpora, storing sanitised HTML rather than raw MIME (which is
what keeps the number this low — attachments are most of a mailbox's bytes and we do not
store them):

| Mailbox | Envelopes | Bodies | Search index | Total |
| --- | --- | --- | --- | --- |
| 10,000 messages | ~12 MB | ~120 MB | ~25 MB | ~160 MB |
| 50,000 messages | ~60 MB | ~600 MB | ~120 MB | ~800 MB |
| 250,000 messages | ~300 MB | ~3 GB | ~600 MB | ~4 GB |

Estimates: ~1.2 KB per envelope row, ~12 KB per stored body, ~20% of body text for FTS.
WS-04 must measure the real figures against a live instance and replace this table — an
estimate in a document is a promise nobody made.

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

- Stage 1: `ceil(messages / 100)` cheap database reads per mailbox, once.
- Stage 2: one IMAP fetch + parse + sanitise per message, once, at a maximum of four
  concurrent per client.
- Steady state: one `POST /sync` per mailbox per interval, plus one `/body` per message
  actually opened that was not already mirrored (which, once backfill completes, is none).

The steady state is **cheaper** than the web client, which re-fetches bodies it has already
shown whenever its 600-second server-side cache expires. The one-time backfill is the
whole cost, and it is bounded, resumable and pausable. If Nextcloud wants a server-side
guard, the honest ask is a bulk-body endpoint — noted in
[../feedback/server-findings.md](../feedback/server-findings.md).
