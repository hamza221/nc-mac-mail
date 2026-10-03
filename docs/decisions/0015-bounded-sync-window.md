<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0015: Bounded sync window plus periodic deep reconcile

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture, from reading `SyncService::getDatabaseSyncChanges`

## Context

`POST /api/mailboxes/{id}/sync` looks like an incremental sync endpoint. Its behaviour, in
`lib/Service/Sync/SyncService.php` and `lib/Db/MessageMapper.php`, is more particular:

- **`ids` is a window, not an inventory.** "New" means not in `ids` **and** newer than the
  oldest `sent_at` among `ids`.
- **`changedMessages` is every id you sent that still exists** — no change detection at
  all; the source carries a `TODO` saying so.
- **`vanishedMessages` holds database ids**, despite the internal name
  `vanishedMessageUids`. It is `array_diff(yourIds, stillExisting)`, so a message is only
  ever reported vanished if you told the server you had it.
- **`newMessages` contains only the newest message of each thread**, via the same self-join
  as [ADR-0014](0014-singleton-enumeration.md).

A full-mirror client that sent its whole known set would upload 50,000 ids and download
50,000 envelopes every cycle — and would *still* miss thread siblings.

## Decision

Two mechanisms, each doing what it is good at.

**A bounded window for liveness.** Each sync sends the **250 most recent message ids** for
that mailbox. That bounds the request and the response, and it covers the messages people
actually act on. Immediately after applying the response, a **tail scan** pages
`GET /api/messages?view=singleton` from the top until it hits a page it already knows,
picking up the thread siblings `newMessages` omits.

**A deep reconcile for completeness.** Weekly per account, and on demand, a full
`view=singleton` enumeration compared against local ids: insert what is missing, delete
what is gone, refresh the rest.

Both are specified in [../architecture/sync-engine.md](../architecture/sync-engine.md).

## Consequences

- Sync traffic is constant per mailbox regardless of mirror size.
- Deletions inside the window are detected in seconds; deletions outside it wait for the
  reconcile. That is the accepted trade, and it is the one thing to say out loud: a message
  deleted in the web client from three years ago may linger locally for up to a week, or
  until the user presses **Check for missing messages**.
- The reconcile is the safety net for every structural hole: siblings, crashes mid-backfill,
  re-created mailboxes, drifted flags.
- `SyncWindow.size` is one constant in one place, tunable from measurements rather than
  taste.

## Alternatives considered

**Send every known id.** Correct against deletions, and quadratic in the wrong direction —
and still misses siblings.

**Send nothing (`ids: []`).** The server returns the whole mailbox as "new", which is a
full enumeration in a single unpaginated response. Fine for the initial prime of a small
mailbox, unacceptable as a two-minute loop.

**Trust `newMessages` alone and drop the tail scan.** One request cheaper per cycle, and
replies in existing threads go missing until the weekly reconcile. In a mail client, a
missing reply is the worst available bug.

## Revisit when

The server implements real change detection (that `TODO`), or offers a
"give me everything since token X" endpoint — either of which would let the window and the
tail scan collapse into one call. Worth raising upstream; noted in
[../feedback/server-findings.md](../feedback/server-findings.md).
