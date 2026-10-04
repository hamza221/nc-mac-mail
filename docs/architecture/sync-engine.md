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
stats            → mailbox.unreadCount, totalCount (the sidebar shows unreadCount only until
                   the mailbox's envelopes are complete; after that it counts the mirror, ADR-0060)
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

### Alongside: avatars — continuous, low priority

Not a sync loop, and it never touches messages, but it runs per account next to the three
above. `AvatarFetcher` asks `GET /api/avatars/image/{email}` about each sender, newest
correspondent first, 4 in flight. It writes the bytes or a `missing` row into `avatar`,
re-asks after 30 days for a photo and 7 days for a 404, and idles 10 minutes between
passes. It pauses offline and in Low Data Mode. Views wait on the row and never request.
[ADR-0061](../decisions/0061-avatars-are-fetched-into-the-mirror-by-sync.md).

### Alongside: server state — at launch, at every deep reconcile, when Settings opens

Everything v2 shows that is not a message is server state, and it reaches a view the same
way a message does: written into the store, observed from there. `ServerStateMirror` is one
actor per signed-in login (ADR-0079 roots this state at `login`) that refreshes all of it in
one pass. Its trigger is `refresh(trigger:)` with `.launch`, `.deepReconcile` or
`.settingsOpened`; `SyncScheduler` calls the second itself in every reconcile pass, right
after the drain (so a queued settings change reaches the server before its old value is read
back), and the app shell calls the other two (WS-25). Two triggers arriving while a pass is
in flight join it rather than starting a second.

The pass reads `GET /api/accounts` first, then runs every other request four at a time. That
is a measured decision: serially, one refresh against the live server was **7.3 s for 25
requests** — every Mail route has a ~210 ms PHP floor, and the quota alone is a 2.4 s IMAP
login. Four at a time it is **2.6–3.1 s** for the same 25 requests (three runs, 2026-10-04),
bounded below by that quota call. `ServerStateLiveTests` re-measures it.

| Kind | Route | Lands in | Scope |
| --- | --- | --- | --- |
| Account settings, signature | `GET /api/accounts` | `account` (signature, editor mode, Sieve flag, … from the payload — never a blank) | account |
| Aliases and their signatures | the `aliases` array every `GET /api/accounts` entry embeds (`AccountsController::index` always adds it), so no request of their own | `alias` | account |
| Quota | `GET /api/accounts/{id}/quota` | `serverResult` kind `quota`, key = local account id | account |
| Delegations | `GET /api/delegations/{id}` | `delegation` | account |
| Sieve script, filters, out-of-office | `GET /api/sieve/active/{id}` (bare `{scriptName, script}`), `/api/filter/{id}` (bare array), `/api/out-of-office/{id}` (envelope around `{state, script, untouchedScript}`, `state` null until configured) — recorded with Sieve on. **Only when the account has Sieve enabled**: off, every one of them is a 400 or a 500, so the mirror writes a disabled row and sends nothing. A part that fails keeps its previous column | `sieveState` | account |
| Quick actions and steps | `GET /api/quick-actions` (every account at once, grouped by `accountId`) | `quickAction`, `quickActionStep` | account |
| Preferences | `GET /api/preferences/{key}`, one request per key, for the fifteen keys the web client's page state carries (`ServerStateConfiguration.webClientPreferenceKeys`) | `preference` | login |
| Text blocks and shares | `GET /api/textBlocks`, `/api/textBlockshares`, `/api/textBlocks/{id}/shares` per own block | `textBlock`, `textBlockShare` | login |
| Trusted senders (individual and domain) | `GET /api/trustedsenders`. The listing omits an address whose domain is also trusted (measured), so the mirror shows exactly what the server lists | `trustedSender` | login |
| Internal addresses | `GET /api/internalAddress` | `internalAddress` | login |
| S/MIME certificates | `GET /api/smime/certificates` | `smimeCertificate` | login |
| Outbox | `GET /api/outbox` (every account at once) | `outboxMessage` | account |

Each kind is fetched and written on its own. One that fails — a 500 from the filter route,
a timeout — leaves its own rows exactly as they were and the pass carries on with the next;
nothing a refresh does ever deletes a row because a request failed. That is the airplane-mode
rule: offline, `apply(conditions:)` makes every trigger a no-op, and the last mirrored state is
what the views keep showing. A kind that succeeds replaces its rows wholesale, because the
server owns every column and a row deleted in the web client must disappear here.

**The outbox** is also polled: after any refresh that leaves it non-empty, it is re-read every
60 seconds until it is empty, then the poll stops by itself. The outbox engine (WS-23) calls
`refreshOutbox()` after it enqueues, sends or deletes, and is the only other caller.

**Follow-up reminders**: when Priority inbox shows the follow-up section, the view model
calls `checkFollowUps(messageIds:)` with the local ids it shows. The mirror sends
`POST /api/follow-up/check-message-ids` with their server ids and writes one `serverResult`
row per message, kind `followUp`, key = local message id, payload
`{"wasFollowedUp": true|false}`. Clearing the `$follow_up` tag on the ones that were answered is
a mutation, so it goes to the queue through the injected `onFollowedUp` hook (WS-22's
operation), not from here.

**Envelope tags** ride on the envelope: every sync, tail scan and reconcile page writes the
envelope's `tags` map into `tag` and `messageTag` in the same transaction as the envelope.

### Alongside: drafts and sending — `OutboxSender` ([ADR-0066](../decisions/0066-drafts-and-outbox.md), [ADR-0083](../decisions/0083-send-converts-the-server-draft-in-place.md))

One actor per mail account (WS-25 starts it). It is not a loop and not the mutation queue:
a send has an undo window, uploads that must finish first and consequences that cannot be
replayed blindly, so it has its own state, persisted on the `draft` row (v3 columns
`sendState`, `sendRequestedAt`, `replacesMessageId`). Timings and the two hooks
(`syncMailbox`, `refreshOutbox`) come in through `OutboxConfiguration`.

**Drafts.** The local `draft` row is authoritative; the composer writes it and calls
`saveDraft(id)`. Five seconds after the *last* call the draft is flushed: `POST /api/drafts`
when it has no `remoteId` (carrying `draftId` = `replacesMessageId` when the draft was opened
from the IMAP Drafts folder, so the server expunges that copy), otherwise
`PUT /api/drafts/{remoteId}`. Local attachments without a server id are uploaded first and
sent as `{"type":"local","id":…}`. The flush stamps `remoteId`, `savedAt` = the `updatedAt`
it flushed (so "dirty" is `savedAt < updatedAt`) and clears `syncError`, through a
column-targeted update so a composer edit landing mid-flush is never overwritten. A `404` on
the `PUT` means the server's background job moved the idle draft (> 5 min untouched) to IMAP
and deleted it; the flush falls back to `POST`. A failed flush writes `syncError` and leaves
the row dirty; reconnecting flushes every dirty draft.

`closeDraft(id)` flushes now, then `POST /api/drafts/move/{remoteId}` puts the draft into the
IMAP Drafts folder and the server deletes its local copy, so the row is deleted here too and
the Drafts mailbox gets a `syncNow` — from then on the draft is a mirrored message. Offline,
the row is marked `sendState = 'closing'` and the move happens on reconnect.
`discardDraft(id)` deletes the server draft (`DELETE /api/drafts/{remoteId}`, a 404 counts as
done) and the row; offline it deletes the row only, and the server's job files the orphan
into Drafts.

**Sending.** `send(draftId:sendAt:)` validates (at least one recipient), writes
`sendState = 'undo'`, `sendRequestedAt = now` and the requested `sendAt`, and returns. For
10 seconds nothing leaves the machine: `undoSend(draftId:)` clears the state and the draft is
a draft again, with no server trace. When the window ends the draft becomes `queued` and is
dispatched as soon as the account is online:

1. Upload every local attachment that has no server id (`POST /api/attachments`). A file
   that is gone or an upload the server rejects ends the send: `sendState = 'failed'`,
   `syncError` = the reason, and the draft stays editable. A transport failure leaves it
   `queued`.
2. Bring the server draft up to date, as a flush does, but with `sendAt` set (the scheduled
   time, or now + 60 s for an immediate send). A draft with `sendAt` is never moved to IMAP
   by the server's job, which pins its id. Only now does the row become `sending`.
3. `POST /api/outbox/from-draft/{remoteId}` with that `sendAt` turns the draft into an outbox
   message *with the same id*.
4. Unless the send is scheduled, `POST /api/outbox/{id}` sends it now. The server deletes the
   outbox row when SMTP and the Sent copy succeed.
5. The local draft row is deleted, `refreshOutbox()` is called (WS-21's mirror is the only
   writer of `outboxMessage`), and, for an immediate send, the Sent mailbox gets a
   `syncNow`.

A server-side failure after step 3 (a 500 from the send) deletes the row too: the message
now lives in the server outbox, the mirrored outbox list shows it as failed, and
`sendNow(outboxId:)`, `copyToSent(outboxId:)` (the same `POST /api/outbox/{id}`; the server
resumes at the copy step when only that failed) and `deleteOutbox(outboxId:)` act on it there.

**Quit and relaunch.** `start()` reads every row with a `sendState`. `undo` whose window has
elapsed is dispatched; one still inside its window waits out the remainder (and can still be
undone). `queued` is dispatched. `sending` is recovered without guessing: `GET
/api/outbox/{remoteId}` answering means step 3 happened, so step 4 runs; a 404 there and on
`PUT /api/drafts/{remoteId}` means the message left the server outbox, which only a send
does once `sendAt` is set — the row is deleted. `closing` is moved. `failed` waits for the
user.

**Offline.** `apply(conditions:)` is the same door the scheduler uses. Offline, a send ends
its undo window in `queued` and stays there; reconnecting dispatches every `queued` row and
flushes every dirty draft.

### On demand: server-computed results (ADR-0067)

`ServerResultFetcher` is the one actor that asks the server for something because a view
wants it. `request(kind:key:)` returns immediately; the view observes the row
(`observeServerResult(kind:key:loginId:)`, or `observeRecipientSuggestions` for autocomplete)
and shows pending until it exists. Kinds, keys and expiry:

| Kind | Key | Route | Expiry |
| --- | --- | --- | --- |
| `threadSummary` | local message id | `GET /api/thread/{id}/summary` | 7 days |
| `smartReply` | local message id | `GET /api/messages/{id}/smartreply` | 1 day |
| `translation` | `<local message id>:<to>` | `POST /ocs/v2.php/translation/translate` with the stored body | 30 days |
| `itinerary` | local message id | `GET /api/messages/{id}/itineraries` | 30 days |
| `eventData` | local message id | `GET /api/thread/{id}/eventdata` | 7 days |
| `autoComplete` | the term | `GET /api/autoComplete?term=` → `recipientSuggestion` | 1 hour |

A `serverResult` payload is always an object with a `status`: `ready` with the answer in
`data`; `empty` when the server answered and had nothing (the 204 of an instance with no LLM
provider); `failed` with a short error name when the request failed. A `failed` row is only
written when there is no `ready` row to keep — a stale answer beats an error. A request whose
row is younger than its expiry sends nothing. The table's expiry is a `ready` row's; an
`empty` row expires after fifteen minutes when the kind's own expiry is longer
(`ServerResultKind.emptyRetryAfter`), so an admin turning LLM processing on reaches the next
open of a message, and a `failed` row after five. The same `(kind, key)` already in flight
joins the request in flight. Offline, nothing is sent and no row is touched.

### Alongside: contacts and the calendar list — `ContactsSync`, `CalendarListSync` (ADR-0069)

Both are one actor per Nextcloud login, not per mail account: one login has one set of
address books and calendars however many mail accounts hang off it. WS-25 starts them. They
speak CardDAV/CalDAV through `DAVClient`, and like everything else here they only write the
store.

**Discovery.** `current-user-principal` on `/remote.php/dav/`, then the principal's
`addressbook-home-set` and `calendar-home-set`. The homes are kept in memory for the life of
the actor; a 404 on a home throws them away and the next pass rediscovers.

**Address book list.** One `PROPFIND Depth: 1` on the home for `resourcetype`, `displayname`,
`sync-token`, `current-user-privilege-set`, `oc:enabled`, `oc:read-only` and
`oc:owner-principal` (fixture `dav-addressbooks-ws24.xml`). Measured semantics:

| Column | From | Note |
| --- | --- | --- |
| `isEnabled` | `oc:enabled` | `0` disables; absent (404) means enabled. Web Contacts stores the toggle **on the server**, so the listing overwrites the mirror, except for a book with a queued `addressBookUpdate` |
| `isReadOnly` | `oc:read-only` = `1`, or no `write-content` in the privilege set | The system "Accounts" book and "Recently contacted" are read-only |
| `sharedBy` | `oc:owner-principal` when it is not our own principal | Absent on own books; `principals/users/<owner>` on a book shared with us (its URL ends `_shared_by_<owner>`); `principals/system/system` on "Accounts" |
| `syncToken` | ours, from the last completed `sync-collection` | The listed token is only compared: equal means nothing changed and the book is skipped without a REPORT |

Every book is mirrored, enabled or not, so flipping the toggle is instant and offline; the
queries hide disabled books.

**The loop.** A pass every **10 minutes**, plus `wake()` — the app calls it when the Mac
wakes or the network comes back — which starts a pass now (a wake during a pass joins it).
Offline, a pass is a no-op and nothing is touched. Per book whose listed token differs from
the stored one:

1. `REPORT sync-collection` with the stored token (none on the first sync). Changed members
   come back with their ETag; members whose ETag equals the mirrored one (our own PUTs echoed
   back) are skipped. Deleted members come back as 404s.
2. The changed members are fetched with `addressbook-multiget`, **100 hrefs per request**,
   parsed with `VCardParser`, and written one card per transaction through
   `MailStore.upsert(contact:emails:phones:memberUids:)` — raw vCard, display columns, emails,
   phones, group members and the FTS row. Measured against the live server: a pass over 5
   books holding 2,013 cards (2,000 of them generated and PUT for the test) took **8.5 s**,
   with 23 multigets, into an on-disk store; the pass after it, with nothing changed, took
   **0.43 s**. One transaction per card is well inside the budget, so there is no batch
   write.
3. A truncated answer (Nextcloud's 507 inside the 207, ADR-0076) loops with the new token.
4. The token and `lastSyncAt` are stamped only after the whole round landed, so an
   interrupted round restarts from the previous token and loses nothing.
5. An initial sync (no token) also deletes every local card the server did not list. A token
   the server refuses — measured: **403** with `Sabre\DAV\Exception\InvalidSyncToken` and a
   `valid-sync-token` precondition — is dropped and the book re-syncs from scratch the same
   way. (A well-formed token *newer* than the server's answers 207 with no changes and the
   server's current token; nothing special is needed.)
6. A book the listing shows **without** a `sync-token` does not support `sync-collection`
   (measured: "Recently contacted" answers 415 `ReportNotSupported`). It is mirrored every
   pass from a `PROPFIND Depth: 1` of ETags instead: differing ETags are multigot, missing
   members deleted.
7. **Favourites** (web Contacts' star, the `{http://nextcloud.com/ns}favorite` DAV property)
   move neither the ETag nor the token, so every token book — skipped or not — also gets one
   `PROPFIND Depth: 1` of `{getetag, nc:favorite}` per pass, applied whole to the book's
   `isFavorite` flags; the multiget and the token-less listing ask for it too
   ([ADR-0092](../decisions/0092-contact-favourites-are-a-dav-dead-property-refreshed-each-pass.md)).

A card with a queued `contactPut`/`contactDelete` is never overwritten or deleted by a
sync: the local edit is in flight, and its drain resolves the difference (below).

**Contact photos → `avatar`.** Every card written with an inline `PHOTO` writes that image
into `avatar` for each of its email addresses, `source = 'contact'`, which `AvatarFetcher`
never overwrites: a contact photo is the user's own choice and beats the server's
Gravatar/favicon guess (ADR-0061). A card that loses its photo, or is deleted, marks its
addresses' contact-photo rows stale so the fetcher asks the server again. URI photos are not
fetched (ADR-0061's rule: no request to a host the server did not vouch for).

**Writes.** Local edits go through WS-22's queue kinds (`contactPut`, `contactDelete`, the
`addressBook*` kinds, `calendarPut`); `ContactWriteHandler` is the queue's `DAVWriteHandling`.
`apply` writes the local effect the moment the user edits (the card row, the avatar);
`revert` puts the `before` snapshot back on Discard; `send` talks to the server:

- `PUT` with `If-Match: <base ETag>` (no `If-Match` on a create); the new ETag is stored when
  the server sends one, nil otherwise so the next sync refetches.
- **412** → `addressbook-multiget` of that one card, then the **per-property reapply**: start
  from the server's card, and for every property name in the write's `editedProperties`
  replace the server's lines with the local ones (removing them when the local card has none).
  Every other property is the server's. A property the server *also* changed since our base
  (its lines differ from the `before` snapshot) is a same-field conflict: **local wins** and
  the conflict is logged (`ContactConflictLog`, OSLog with the property name only). The merged
  card is PUT once with the fresh ETag.
- A second 412 gives up: `send` throws `preconditionFailed` and the queue parks the row as a
  **conflict row** (`lastError = "conflict"`, shown with Retry and Discard). Retry runs the
  reapply again. ADR-0082.
- `DELETE` with `If-Match`; a 412 refetches the ETag and deletes once more (the user's delete
  wins over an edit elsewhere, and is logged as a conflict); 404 is already done.
- `calendarPut` refused with 409 CalDAV `no-uid-conflict` (the calendar already holds the
  UID — scheduling's own copy of an invitation, or an itinerary imported before) → the same
  body is PUT once at the href the 409 names, without `If-Match`; a second 409 parks the row
  as a conflict. ADR-0093.

**Calendar list.** `CalendarListSync` runs at the same cadence and on `wake()`: one
`PROPFIND Depth: 1` on the calendar home (`resourcetype`, `displayname`,
`supported-calendar-component-set`, `current-user-privilege-set`, `calendar-color`,
`calendar-order`, `oc:read-only`, `oc:owner-principal`; fixture `dav-calendars-ws24.xml`)
plus `schedule-default-calendar-URL`, which Nextcloud answers on the **principal**, not on the
schedule inbox where RFC 6638 puts it (measured). Only `calendar` collections are kept —
inbox, outbox and trash bin are not. Writability is `write-content` in the privilege set and
no `oc:read-only`: the birthday calendar is read-only and answers no `oc:read-only`. The list
replaces the login's `calendar` rows wholesale; a failed request replaces nothing.

**Social avatars** are not fetched here. The Contacts app's
`PUT /index.php/apps/contacts/api/v1/social/avatar/{network}/{addressBookUri}/{contactUid}`
(verified live) makes the *server* download the picture and write it into the card's `PHOTO`;
the next `sync-collection` brings it into the mirror like any other edit.

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
| 401 | App password revoked or gone | `syncFailureCount++` with `lastSyncError = unauthorized`, like any failure. The app watches that column and raises the session-expired modal once per login (`SessionExpiryTrigger`, ux-spec "Errors"). A 401 on a body is recorded on its mailbox the same way, counted against no message, and stops stage 2 for the run |
| 403 | Delegation or account gone | Mark the account; do not delete local data without asking |
| 428 | Mailbox not cached (the `sync` route's own code) | Re-prime with `init: true` |
| 429 / 503 + `Retry-After` | Rate limited or overloaded | Honour the header; halve concurrency for 10 minutes |
| Timeout | Big mailbox, slow IMAP | Backoff, `syncFailureCount++`, move on. Three consecutive failures marks the mailbox in the UI |

A failing mailbox never blocks another, never clears what is mirrored, and never turns
into a modal. The one exception is a 401, which is not the mailbox's failure but the
login's.

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
