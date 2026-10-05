<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-32 — Search parity

**Wave 3, after WS-18, WS-25. Size: M.**

## Goal

§4.6 on the local index.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)

## You own

`NCMailStore/Search/**`, `NextcloudMail/Views/Search/**`

## Build

- Chips: Has attachment, Unread, To me.
- "Search parameters" sheet: subject, body, date range, from (max 1), to, cc, bcc, tags,
  important, favorite, attachments, mentions me.

Rules that are easy to get wrong:

- **Terms need ≥ 2 characters.**
- **From takes at most one address**; the other recipient fields take many.
- **Everything runs on the local index** — no server search call.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Each filter has a query test.
- Results stay instant offline.

## Out of scope

The store outside `Search/**`, including the tables you query (WS-18). Rendering the result
rows beyond the search surface (WS-29). The app shell and window (WS-25). Contacts search
(WS-35).

## Report

Additionally: which filters needed index changes rather than plain queries, and the result
latency on the largest mirrored mailbox you tested.
