<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0068: Settings the server must validate are online-only commands

**Status:** Proposed
**Date:** 2026-10-03
**Decided by:** v2 roadmap, to be confirmed by the owning workstream

## Context

ADR-0005 queues every mutation and replays it. That is right for flags and moves, where
the user's intent is unambiguous and the replay cannot meaningfully fail validation. v2
adds settings the server must validate — credentials, Sieve scripts, filters — where a
queued write can be rejected hours later with nobody there to fix it.

## Decision

Settings the server must validate are online-only commands. This is the one deliberate
exception to "queue every mutation".

- Applies to: mail-server credentials, Sieve connection, Sieve script, mail filters,
  autoresponder, S/MIME import, delegation, account creation, and the account connection
  test.
- Mechanism: a `SettingsCommands` actor in `NCMailSync` performs the request. On success
  it writes the server's resulting state into the store. It returns `CommandOutcome`
  (success, or a `MailError` with the server message).
- What the view awaits: only the outcome, to show a spinner or an error (for example 422
  Sieve syntax errors). It never renders response data; data is read from the store.
- Why: queueing these offline would accept input the server will reject hours later, with
  nobody there to fix it.
- Everything else (tags, text blocks, quick actions, preferences, mailbox
  create/rename/delete, internal addresses, trusted domains, signatures, aliases) goes
  through the mutation queue as new operation kinds.

## Consequences

- Validation errors reach the user while they are still looking at the form, with the
  server's own message — a 422 Sieve syntax error points at the script just typed.
- Views stay database readers: the awaited value is an outcome, never data.
- The cost is that these settings cannot be changed offline, and the architecture now has
  a named exception that every reviewer must know is deliberate.

## Alternatives considered

**Queue these like everything else.** The replay can be rejected hours later with nobody
there to fix it; the queued intent was never valid.

**Let settings views call the network and render the response.** Breaks the store-reader
rule for data, and the resulting state would exist in the view but not in the mirror.

## Revisit when

The server offers offline-validatable schemas for these settings, or the list above grows
enough that "exception" stops being the right word.
