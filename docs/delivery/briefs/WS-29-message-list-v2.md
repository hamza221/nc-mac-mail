<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-29 — Message list parity

**Wave 3, after WS-21, WS-22, WS-25. Size: L.**

## Goal

§2.4 and §4.1–§4.5 parity.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)

## You own

`NextcloudMail/Views/MessageList/**`

## Build

- Layouts: vertical split (current), horizontal split, list. Compact mode.
- Favorites section; Priority sections (Favorites / Follow up / Important / Other); date
  groups Last hour → years.
- Row adornments: tags, attachment chips, AI summary preview, draft prefix.
- Hover quick actions; multi-select bulk header; `⌘A`; drag source; "Open in New Window".

Rules that are easy to get wrong:

- **Sort order is written to the server preference**, not kept locally.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every listed row live.
- Layout switching keeps selection.

## Out of scope

The triage actions behind the hover quick actions and bulk header (WS-31). The message
view the list selects into (WS-30). The sidebar feeding the mailbox selection (WS-28).
The mirror that fills the rows (WS-21) and the queue kinds the actions use (WS-22). Search
results rendering (WS-32).

## Report

Additionally: what the three layouts shared and where they diverged, and how the date
grouping behaved at the year boundaries.
