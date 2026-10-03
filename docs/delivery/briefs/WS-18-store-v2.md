<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-18 — Store v2: migrations, DAOs, observations

**Wave 1, no dependencies. Size: XL.**

## Goal

Every table v2 needs, as a `v2` migration that reproduces the updated
`docs/reference/schema.sql`.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../architecture/local-mirror.md](../../architecture/local-mirror.md)
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md) — the `serverResult` tables
- [../../decisions/0025-rowid-tables-for-anything-observed.md](../../decisions/0025-rowid-tables-for-anything-observed.md)
- [../../decisions/0024-fts-deletes-in-a-trigger.md](../../decisions/0024-fts-deletes-in-a-trigger.md)
- [../../decisions/0034-the-store-returns-its-own-sequence.md](../../decisions/0034-the-store-returns-its-own-sequence.md)

## You own

`NCMailStore/**` except `Search/**`

## Build

- Your first commit updates [../../architecture/local-mirror.md](../../architecture/local-mirror.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

One migration `v2` — **never edit `v1`**, see
`Packages/NCMailStore/Sources/NCMailStore/Migrations.swift` — adding tables for:

- `draft`, `draftRecipient`, `draftAttachment`, `outboxMessage`;
- `alias`; account columns for editorMode, signatureAboveQuote, trashRetentionDays,
  searchBody, classificationEnabled, imipCreate, order, and the flags discovered by WS-16;
- `preference`, `textBlock`, `textBlockShare`, `quickAction`, `quickActionStep`,
  `trustedSender`, `internalAddress`, `delegation`, `smimeCertificate`;
- `sieveState` (connection, script text, filters JSON, out-of-office JSON);
- `serverResult` (kind, key, payloadJSON, fetchedAt;
  [ADR-0067](../../decisions/0067-server-results-are-rows.md)), `recipientSuggestion`,
  `filesListing`, `smartPickerResult`;
- `addressBook`, `contact` (raw vCard plus extracted display columns and ETag),
  `contactEmail`, `contactPhone`, `contactGroupMember`;
- `contactSearch` (FTS5, with a delete trigger per
  [ADR-0024](../../decisions/0024-fts-deletes-in-a-trigger.md));
- `calendar`, `team`, `teamMember`;
- `snooze` (messageId, until).

Rules that are easy to get wrong:

- Tags reuse the existing `tag`/`messageTag`.
- Observed tables are rowid tables
  ([ADR-0025](../../decisions/0025-rowid-tables-for-anything-observed.md)).
- DAOs and `AsyncSequence` observations follow
  [ADR-0034](../../decisions/0034-the-store-returns-its-own-sequence.md): no GRDB type
  crosses the boundary.
- Column-level design is this workstream's; anything a later workstream needs is requested
  through its report and added as `v3`, `v4`, ….

## Acceptance

- The migration test matches `schema.sql`.
- Deleting a Nextcloud login leaves no orphans in any table, including contacts and FTS.
- Every table has a query test.

## Out of scope

The search tables and queries in `NCMailStore/Search/**` (WS-32). The endpoints whose
payloads fill these tables (WS-16, WS-17). Mirroring data into the tables (WS-21, WS-24).
Queue kinds that mutate them (WS-22). Drafts and outbox behaviour (WS-23).

## Report

Additionally: any column whose design you expect a later workstream to contest, and what a
`v3` request should look like so the follow-up migrations stay small.
