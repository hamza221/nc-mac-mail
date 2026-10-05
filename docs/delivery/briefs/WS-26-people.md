<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-26 — People: recipient suggestions and contact cards

**Wave 3, after WS-24, WS-25. Size: M.**

## Goal

ADR-0072, plus the contact card used everywhere a person appears.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0072-local-first-autocomplete.md](../../decisions/0072-local-first-autocomplete.md) — the decision this workstream implements
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md) — the `recipientSuggestion` cache the server supplement lands in

## You own

`NextcloudMail/Views/People/**`

## Build

Build in `NextcloudMail/Views/People/`:

- `RecipientSuggestionProvider` (local query, then `ServerResultFetcher` supplement; also
  implements WS-20's `MentionProvider`);
- `ContactCardPopover(email:)` for §5.11: contact match, Reply, Add to contact (search,
  then queue `contactPut`), New contact, Copy address;
- `RecentMailList(email:)` for the contact detail pane.

Rules that are easy to get wrong:

- **Local results come first** (ADR-0072): the contacts mirror, contact groups, own
  identities and aliases, and addresses from mirrored mail. The server supplement
  (`GET /api/autoComplete?term=`) runs only after local results are shown, landing in the
  `recipientSuggestion` cache table per ADR-0067.
- **Ranking** per ADR-0072: own identities last, then contacts by recent interaction, then
  mail-derived addresses by frequency.
- **"Add to contact" works offline**: search for the contact, then queue `contactPut` — no
  direct HTTP.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Autocomplete is under 50 ms on 10,000 contacts offline (measure).
- "Add to contact" offline appears in web Contacts after reconnect.

## Out of scope

The contacts and calendars mirror that feeds the suggestions (WS-24). The editor and its
mention UI — you only implement its `MentionProvider` (WS-20). The composer chip fields
that consume the provider (WS-27). The message view that hosts the contact card (WS-30).
Browsing, viewing and editing contacts (WS-35).

## Report

Additionally: the measured autocomplete latency at 10,000 contacts, and whether the
server supplement ever produced suggestions the local sources missed.
