<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0090: Editing an outbox entry converts it to a local draft

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** orchestrator (Main), for WS-27

## Context

§4.9: clicking an Outbox item opens "Edit message", pauses the schedule, and closing
without sending restores the send time. The web client does that with
`PUT /api/outbox/{id}`. `OutboxSender` (WS-23) has no edit route, sends are draft rows
(ADR-0083), and the composer may not talk HTTP.

## Decision

Opening an outbox entry copies it into a new local draft row (recipients, subject, body,
flags, `sendAt`; uploads referenced by their server ids) and cancels the server entry with
`deleteOutbox`. Without attachments the cancel happens at open, which pauses the schedule.
With attachments it waits for the draft's first server save, because the server re-links
`{"type":"local","id":…}` uploads to the message that names them, and deleting the old entry
first would delete the uploads with it. Sending goes through the normal draft send. Closing
without sending re-schedules the draft at its original time when that is still in the
future; otherwise the draft is filed in Drafts.

## Consequences

- No new engine surface; the outbox edit is an ordinary draft afterwards.
- With attachments the old entry stays live for up to the first save (about 5 s); if its
  time falls in that window the message goes out and the edit becomes a second message.
- Close-without-send recreates the entry with a new server id rather than restoring the old
  one, and goes through the 10 s undo window silently (no banner for scheduled sends).

## Alternatives considered

**`OutboxSender.editOutbox` over `PUT /api/outbox/{id}`.** The web's behaviour exactly; a
WS-23 change, deferred to wave 4.

## Revisit when

`OutboxSender` gains an outbox edit route.
