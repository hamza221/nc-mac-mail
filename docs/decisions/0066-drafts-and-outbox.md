<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0066: Drafts are local rows synced to the server's draft API; sending goes through the server outbox, driven by its own actor, not the mutation queue

**Status:** Proposed
**Date:** 2026-10-03
**Decided by:** v2 roadmap, to be confirmed by the owning workstream

## Context

ADR-0005 queued mutations and noted that a queued send deserves its own record. This is
that record. A send is not a flag flip: it has attachments to upload first, an undo
window users expect, scheduled delivery, and consequences that cannot be replayed blindly
hours later. The server offers a draft API, an outbox API, and an OCS `message/send`
endpoint with known limits.

## Decision

Drafts are local rows synced to the server's draft API; sending goes through the server
outbox, driven by its own actor, not the mutation queue.

- Resolves ADR-0005's note that a queued send deserves its own record.
- Lifecycle: `draft` rows are authoritative locally. `OutboxSender` creates and updates
  server drafts (`POST/PUT /api/drafts`) 5 s after the last edit. On composer close it
  calls `POST /api/drafts/move/{id}`.
- Sending: send = a local 10-second undo window, then attachment uploads
  (`POST /api/attachments`), then `POST /api/outbox` with `draftId`, then
  `POST /api/outbox/{id}` unless `sendAt` is set.
- Scheduled sends stay on the server, and the Outbox view reads mirrored
  `GET /api/outbox` rows.

## Consequences

- Drafts survive crashes and appear on other clients within seconds of the last edit, and
  undo send costs nothing: for 10 seconds nothing has left the machine.
- Scheduled sends fire even when this Mac is asleep, because the server owns them.
- The cost is a second replay mechanism beside the mutation queue: `OutboxSender` is its
  own actor with its own retry story, and a send started offline waits for connectivity
  rather than being queued like a flag change.
- A crash between outbox steps can leave a server draft or outbox row to reconcile; the
  send is not idempotent.

## Alternatives considered

**Send through the mutation queue.** The queue replays blindly; a send replayed hours
later, duplicated or out of order, is a visible disaster in someone else's inbox.

**OCS `message/send`.** Limited to 5 per 100 s and has no attachments.

**A purely local undo-then-SMTP model.** The server outbox already exists, carries
scheduled sends, and keeps other clients consistent.

## Revisit when

The server offers idempotent send keys.
