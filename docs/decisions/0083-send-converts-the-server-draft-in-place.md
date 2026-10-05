<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0083: A send converts the server draft in place, with `sendAt` pinned, and its state lives on the draft row

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-23, from the nextcloud/mail source (`OutboxController`, `DraftsService`,
`DeleteDraftListener`, `LocalMessageMapper::findDueDrafts`) and confirmed against the live
server (`OutboxLiveTests`)

## Context

ADR-0066 said a send is `POST /api/outbox` "with `draftId`", then `POST /api/outbox/{id}`.
Reading the server and running it showed three things that sentence did not know:

- `draftId` on `POST /api/drafts` and `POST /api/outbox` is **not** a `/api/drafts` id. It
  is the id of a *mirrored IMAP message* in the Drafts folder; `DeleteDraftListener`
  flags it `\Deleted` and expunges it. Passing a server draft id there would expunge an
  unrelated message.
- The server has its own job (`DraftsService::flush`) that moves every draft untouched for
  300 s **and with `send_at` NULL** to the IMAP Drafts folder and deletes it. So a
  `/api/drafts` id can vanish under an open composer, and a `PUT` on it answers 404.
- `POST /api/outbox/from-draft/{id}` turns a draft into an outbox message **keeping the
  same id**, and the routes filter by type: `PUT /api/drafts/{id}` 404s once it is an
  outbox message, `GET /api/outbox/{id}` 404s while it is still a draft, and both 404 once
  the send chain has deleted it.

ADR-0066 also asked for a 10 s undo window "persisted in the row" and a `failed` state, and
the v2 `draft` table had no columns for either.

## Decision

- **The send sequence** after the undo window is: upload pending attachments → bring the
  server draft up to date (`POST` or `PUT /api/drafts`) **with `sendAt` set** (the
  scheduled time, or now + 60 s) → `POST /api/outbox/from-draft/{id}` with that `sendAt` →
  `POST /api/outbox/{id}` unless scheduled. The server draft *becomes* the outbox message;
  there is no second object and no draft to clean up afterwards.
- **Pinning `sendAt`** keeps the server's draft job off the draft from the moment the send
  is under way, which is what makes recovery decidable: for a row in `sending`, "neither a
  draft nor in the outbox" can only mean "sent".
- **`draftId`** is sent only on a create, and only as `draft.replacesMessageId` — the IMAP
  Drafts message the composer was opened from (WS-27 sets it).
- **State on the row** (v3): `draft.sendState` ∈ `undo | queued | sending | failed |
  closing`, `draft.sendRequestedAt` (the undo window is `sendRequestedAt + 10 s`, so it
  survives a quit), `draft.replacesMessageId`. A row leaves the table once the server owns
  the message (enqueued, sent, or moved to IMAP); failures after that are the mirrored
  outbox's to show.
- **Immediate sends use `now + 60 s`**, not `now`: if the app dies between `from-draft` and
  the send, the server's outbox job sends the message itself within a minute or so.

## Consequences

- Undo costs nothing and leaves nothing: for 10 s no request is made (verified live —
  zero requests, no outbox row, nothing in Drafts or Sent).
- A crash at any step resumes without a duplicate send: `undo`/`queued` rows redo idempotent
  steps; `sending` rows are recovered by asking the two typed routes.
- The cost: a send of a draft whose server copy the job already moved (composer idle > 5 min,
  then Send) recreates the server draft, and the moved IMAP copy stays in Drafts unless the
  composer knew its message id. The web client has the same gap.
- The 60 s grace means a server-side failure of the immediate send is retried by the server's
  job once more before the user acts on it — the same behaviour the web client gets from its
  10 s `sendAt`.

## Alternatives considered

**`POST /api/outbox` with the full message, then `DELETE /api/drafts/{id}`.** Two objects,
a crash window in which both exist, and the delete is a second non-idempotent call. It is
also what ADR-0066 literally said, with `draftId` misread.

**Keep the undo window in memory.** A quit inside the window would either lose the send or
send it unasked on relaunch; the brief requires neither.

**`sendAt = now`.** The server's job could then race the explicit send; the web client
avoids that with a future `sendAt`, and so do we.

## Revisit when

The server offers idempotent send keys (ADR-0066's trigger), or its draft job stops
deleting drafts it has moved.
