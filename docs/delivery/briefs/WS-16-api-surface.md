<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-16 — Mail API surface: endpoints, models, flag discovery

**Wave 1, no dependencies. Size: L.**

## Goal

Every user-facing route in `plan/API.md` that the app does not call yet, decoded against a
recorded fixture.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../../plan/API.md](../../../plan/API.md) — the authoritative route list; the Admin
  settings section is excluded
- [../../architecture/networking.md](../../architecture/networking.md) — retryability rules
- [../../reference/api-payloads.md](../../reference/api-payloads.md)

## You own

`NCMailNet/Endpoints/**`, `NCMailNet/Client/**`, `NCMailCore/Models/**`

## Build

- Your first commit updates [../../architecture/networking.md](../../architecture/networking.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

`Endpoint` factories in `Endpoints.swift` for every route in these `plan/API.md` sections:

- Accounts: create, PUT, PATCH, DELETE, signature, smime-certificate, quota, test.
- Aliases; Auto configuration; Mailboxes: create, PATCH, DELETE, clear, read, stats, repair.
- Messages: source, export, itineraries, dkim, tags, snooze/unsnooze, mdn, save attachment to
  Files, attachments zip, file, smartreply.
- Threads: snooze, unsnooze, summary, eventdata. Drafts; Outbox; Attachments upload
  (multipart); Tags.
- autoComplete and contactIntegration; Preferences PUT; trusted senders domain type; internal
  addresses.
- Sieve and filters; Out of office; Follow-up; Quick actions and action steps; Text blocks and
  shares.
- S/MIME certificates; Delegation; Mailing list unsubscribe; `POST /api/oauth/state`.
- Admin routes are excluded
  ([ADR-0064](../../decisions/0064-v2-parity-scope.md)).

Also these non-Mail routes, each **unverified — confirm against the live server first**, with
the confirmed path written to
[../../reference/api-payloads.md](../../reference/api-payloads.md):

- core translation (OCS `translation/languages` and `translation/translate`, or
  TaskProcessing if that is what the server offers);
- Smart Picker reference providers and search;
- notifications OCS v2 list and delete;
- files_sharing OCS share-link creation;
- Circles/Teams OCS.

Rules that are easy to get wrong:

- `MailClient` gains `upload(_ endpoint:, multipart:)` for `POST /api/attachments` and
  S/MIME import.
- Retryability per endpoint follows
  [../../architecture/networking.md](../../architecture/networking.md): **sends, moves and
  creates are never retried**.

**Flag discovery** — record, in a new `docs/reference/server-flags.md`, how the client learns
each appendix flag without the web page's initial state:

- `allow-new-accounts`, `disable-scheduled-send`, `disable-snooze`, `llm_*`,
  `context_chat_available`, `importance_classification_default`,
  `enable-system-out-of-office`, `attachment-size-limit`, `google-oauth-url`,
  `microsoft-oauth-url`.
- Candidate sources: capabilities, preferences, account payload fields, or probing.
- Contingency: a flag with no API source is treated as "feature on". Its server error is
  surfaced in the UI as the server's message, and the gap is appended to
  `docs/feedback/server-findings.md`.

## Acceptance

- Every new endpoint has a decode test against a recorded fixture.
- `server-flags.md` covers every appendix flag.

## Out of scope

DAV, vCard and iCalendar (WS-17). Store tables for the new payloads (WS-18). Recording
fixtures infrastructure (WS-19). Mirroring the new state into the store (WS-21). Queue kinds
and settings commands that call these endpoints (WS-22).

## Report

Additionally: which flags had no API source and went through the contingency, and any route
in `plan/API.md` whose live payload disagreed with the plan.
