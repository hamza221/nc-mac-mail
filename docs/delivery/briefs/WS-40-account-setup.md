<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-40 — Mail account setup

**Wave 4, after WS-22, WS-25. Size: L.**

## Goal

§1 parity: adding a mail account — auto, manual IMAP/SMTP, Google, Microsoft — behaves
exactly like the web client's setup dialog.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [ADR-0003](../../decisions/0003-local-first-full-mirror.md)
- [ADR-0064](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md) — §1.1–§1.5
- [ADR-0068](../../decisions/0068-settings-commands.md) — account creation and the
  connection test are online-only commands, not queued mutations

## You own

`NextcloudMail/Views/AccountSetup/**`

## Build

- Auto mode with the same button label sequence (ISPDB → MX → connectivity → auth →
  loading). Manual IMAP/SMTP with port/security coupling and SMTP mirroring until edited.
- Google/Microsoft via `POST /api/oauth/state`, then `ASWebAuthenticationSession` to the
  server's OAuth URL.
  - Contingency: if the session cannot observe completion, open the default browser and
    poll `GET /api/accounts/{id}/test` every 2 s for up to 10 min. Closing the flow deletes
    the temporary account.
- Every §1.5 error string. Hidden when `allow-new-accounts` is off.

Rules that are easy to get wrong:

- Account creation and the connection test go through `SettingsCommands`
  (ADR-0068) — they are online-only, and the view awaits only the outcome.
- SMTP fields mirror the IMAP fields **until the user edits them**, after which the
  coupling is severed for that field.

Universal rules:

- Your first commit updates [`docs/product/ux-spec.md`](../../product/ux-spec.md) with the
  screens/behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in
  [`docs/product/parity.md`](../../product/parity.md) in your PR, with the evidence (test
  name or manual check) in the note column.

## Acceptance

- Add an IMAP account and a Gmail account (live).

## Out of scope

Per-account settings once the account exists (WS-39). The app settings window the setup
sheet is launched from, including its "add account" entry (WS-38). The command machinery
itself (WS-22). OAuth routes and models (WS-16).

## Report

Additionally: whether `ASWebAuthenticationSession` could observe OAuth completion against
the live server, or the polling contingency was needed.
