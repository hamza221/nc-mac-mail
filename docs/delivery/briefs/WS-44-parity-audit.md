<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-44 — Parity audit

**Runs at the end, after everything. Size: M.**

## Goal

Walk every row of `docs/product/parity.md` on a live server, including the `v1` rows, and
leave no row `Planned`.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [ADR-0003](../../decisions/0003-local-first-full-mirror.md)
- [ADR-0064](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md) — which is all of
  them: you own the status column

## You own

The status column of `docs/product/parity.md`

## Build

- Walk every row of `docs/product/parity.md` on a live server, including the `v1` rows.
- Set each to `Done` (with evidence) or reopen it as a named defect in the PR body against
  the owning WS.
- M16 exits when no row is `Planned`.

Rules that are easy to get wrong:

- The whole job **is** the status column: every status edit carries evidence (test name or
  manual check) in the note column — a row flipped to `Done` without evidence is not
  audited.
- You do not fix defects; you name them in the PR body against the owning WS from the
  workstreams table.

## Acceptance

- Every row is `Done` with evidence, or reopened as a named defect against its owning WS.
- No row is `Planned`.

## Out of scope

Fixing anything: every defect goes back to the owning workstream named in the row. Editing
any column other than status and its evidence note. The feedback documents (WS-43).

## Report

The pull request body carries the reopened defects, one per row, each naming the owning WS.
