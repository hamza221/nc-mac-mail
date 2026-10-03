<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-23 — Drafts and outbox engine

**Wave 2, after WS-16, WS-18. Size: L.**

## Goal

[ADR-0066](../../decisions/0066-drafts-and-outbox.md), implemented.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0066-drafts-and-outbox.md](../../decisions/0066-drafts-and-outbox.md) — the lifecycle you are building
- [../../architecture/sync-engine.md](../../architecture/sync-engine.md)
- [../../reference/api-payloads.md](../../reference/api-payloads.md)

## You own

`NCMailSync/Outbox/**`

## Build

- Your first commit updates [../../architecture/sync-engine.md](../../architecture/sync-engine.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

`actor OutboxSender` in `NCMailSync/Outbox/`:

- `saveDraft(_ draftId: Int64)` (debounced 5 s server sync);
- `closeDraft(_:)` (`drafts/move`);
- `discardDraft(_:)`;
- `send(draftId: Int64, sendAt: Date?) async throws` (enters a 10 s undo window persisted in
  the row, so a quit during the window sends on next launch only if the window has elapsed);
- `undoSend(draftId:)`, `sendNow(outboxId:)`, `copyToSent(outboxId:)`,
  `deleteOutbox(outboxId:)`.

Rules that are easy to get wrong:

- Ordering: attachment uploads finish before `POST /api/outbox`. A failed upload leaves the
  draft in `failed` state with the reason.
- After sending: the Sent mailbox gets a `syncNow`. The interaction "recently contacted" and
  the draft cleanup are server behaviour; **verify both and record them in
  [../../reference/api-payloads.md](../../reference/api-payloads.md)**.
- Offline: a send waits in `queued` until online.

## Acceptance

- Compose → send → message in Sent (live).
- Undo within 10 s leaves no server trace.
- Offline send goes out on reconnect.
- Scheduled send appears in the outbox list.

## Out of scope

The draft and outbox endpoints (WS-16) and tables (WS-18). The mutation queue — sending is
deliberately not a queue kind (WS-22). Mirroring the outbox list (WS-21). Starting the
actor per account (WS-25). The composer and outbox views (WS-27).

## Report

Additionally: what the server actually does about "recently contacted" and draft cleanup on
send, and how the persisted undo window behaved across a quit.
