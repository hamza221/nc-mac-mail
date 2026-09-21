<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Glossary

*Terms that mean two things in this codebase unless we pin them down.*

**Envelope** — a message's metadata: subject, sender, recipients, date, flags, preview
text, thread id. What a list row needs. One JSON object from `GET /api/messages`, one row
in `message`. Does not include the body.

**Body** — the content: sanitised HTML and/or plain text, plus attachment metadata and the
per-message security verdicts. One row in `messageBody`. Fetched separately, and in v1
mirrored for every message.

**Message** — envelope plus body. Used loosely in prose; in code, prefer `Envelope` or
`MessageBody`, because they have different lifecycles and different fetch costs.

**Thread** — messages sharing a `threadRootId`, which the **server** computes from
`Message-ID`, `References` and `In-Reply-To`. We never recompute it
([ADR-0014](../decisions/0014-singleton-enumeration.md)). Threads are per mailbox, the same
as in the web client.

**Mailbox** — what IMAP calls a mailbox and users call a folder. The API says mailbox; the
UI says folder; the code says mailbox. The one exception is the message move parameter,
which upstream spells `destFolderId`.

**`databaseId`** — the numeric primary key the API wants everywhere. On a mailbox payload
it is the field literally called `databaseId`; the field called `id` is
`base64_encode(name)` and is not an identifier for anything we do.

**`dateInt`** — the message's sent time, unix seconds. Doubles as the pagination cursor for
`GET /api/messages`.

**Special role** — `inbox`, `drafts`, `sent`, `archive`, `junk`, `trash`, `flagged`, `all`.
Comes from `specialUse[0]`, which is a string or the integer `0`.

**Mirror** — the complete local copy of subscribed mailboxes
([ADR-0003](../decisions/0003-local-first-full-mirror.md)). Not a cache: nothing expires,
nothing is evicted.

**Backfill** — the two-stage initial download. Stage 1 envelopes, stage 2 bodies.

**Sync** — the steady-state incremental update: `POST /api/mailboxes/{id}/sync` plus a tail
scan, on an interval.

**Deep reconcile** — the periodic full enumeration that catches what sync structurally
cannot ([ADR-0015](../decisions/0015-bounded-sync-window.md)).

**Sync window** — the 250 most recent message ids sent as `ids` on a sync request. Bounds
both request and response.

**Tail scan** — paging `GET /api/messages` from the newest until a fully-known page, after
each sync, because `newMessages` only reports thread heads.

**Pending operation** — a queued mutation in `pendingOperation`, waiting to reach the
server ([ADR-0005](../decisions/0005-offline-mutation-queue.md)).

**Drain** — replaying pending operations to the server, in order, per account.

**Priming** — `POST /api/mailboxes/{id}/sync {"init": true}`, which makes the **server**
cache the mailbox from IMAP. Required before the mailbox can be enumerated at all.

**Blocked content** — remote images, which the server replaces with a placeholder and
stashes in `data-original-src` before we ever see the HTML
([../architecture/rendering.md](../architecture/rendering.md)).

**App password** — the per-device credential from Login Flow v2, stored in the Keychain,
revocable server-side. Never the user's Nextcloud password.
