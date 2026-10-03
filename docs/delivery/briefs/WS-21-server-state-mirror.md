<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-21 — Server-state mirror

**Wave 2, after WS-16, WS-18. Size: L.**

## Goal

Every piece of server state v2 shows is mirrored into the store on a schedule, never fetched
by a view.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../architecture/sync-engine.md](../../architecture/sync-engine.md)
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md) — `ServerResultFetcher` implements it

## You own

`NCMailSync/Sync/**`, `NCMailSync/Mirror/**`

## Build

- Your first commit updates [../../architecture/sync-engine.md](../../architecture/sync-engine.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

Mirror into the store:

- Envelope tag mapping into `messageTag` (currently missing in `Mirror/MirrorMapping.swift`).
- Account settings, aliases and signatures (**stop writing nil signatures**).
- Preferences.
- Text blocks and shares, quick actions and steps, trusted senders (individual and domain),
  internal addresses, delegations, S/MIME certificates.
- Sieve state when enabled, quota, outbox list (every 60 s while non-empty), follow-up
  re-check (`POST /api/follow-up/check-message-ids` when Priority inbox is shown).

Rules that are easy to get wrong:

- Cadence: refreshed at launch, at every deep reconcile, and when Settings opens.
- `ServerResultFetcher` actor implementing
  [ADR-0067](../../decisions/0067-server-results-are-rows.md) for summaries, smart replies,
  translations, itineraries, event data and autoComplete supplements, with
  `request(kind:key:)` returning immediately.

## Acceptance

- Each mirrored kind has a fake-transport test including a failure path.
- Airplane mode keeps the last mirrored state visible.

## Out of scope

The endpoints (WS-16) and tables (WS-18) you consume. Mutations and settings commands
(WS-22). Outbox sending (WS-23). Contacts and calendars mirroring (WS-24). Starting the
`ServerResultFetcher` per session (WS-25). The views that observe the mirrored rows (WS-28,
WS-29, WS-30, WS-38, WS-39).

## Report

Additionally: which mirrored kinds needed store columns WS-18 did not foresee (the `v3`
requests), and the measured cost of a full settings refresh at launch.
