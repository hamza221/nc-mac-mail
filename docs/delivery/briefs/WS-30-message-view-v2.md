<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-30 — Message view parity

**Wave 3, after WS-21, WS-22, WS-25, WS-26. Size: XL.**

## Goal

§5 parity except calendar (WS-34) and bubbles (WS-26).

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../architecture/rendering.md](../../architecture/rendering.md) — the pipeline you extend
- [../../architecture/security.md](../../architecture/security.md) — checkpoint 2, walked for every WebView change

## You own

`NextcloudMail/Views/Message/**`, `NextcloudMail/WebView/**`

## Build

- Thread mode with expandable messages; smart replies and thread summary through
  `serverResult`.
- Follow-up banner, unsubscribe (one-click / URL / mailto), MDN banner, phishing warning
  from `phishingJSON`, S/MIME status, translation banner and modal.
- PGP notice ("This message is encrypted with PGP and can't be read in this app."),
  "Contains AI content" badge, trust domain.
- View source, download `.eml`, save message or attachment to Files (WS-33 picker), zip
  download, Quick Look attachment preview, copy direct link, whole-thread print.

Rules that are easy to get wrong:

- **Walk security checkpoint 2 for every WebView change** — no exceptions, however small
  the change looks.
- **PGP mail gets the honest notice, nothing more** (ADR-0064): no decryption path, no
  Mailvelope bridge.
- **Server-computed content (smart replies, thread summary, translations) is read from
  `serverResult` rows** (ADR-0067), never awaited from the network in the view.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every listed §5 row live.

## Out of scope

Calendar, iMIP, tasks and itineraries (WS-34). The contact bubbles and contact card
(WS-26). The Files picker behind save-to-Files (WS-33). The message list (WS-29). The
mirror (WS-21) and queue kinds (WS-22).

## Report

Additionally: every WebView change you made and the checkpoint-2 walk for each, and
whether whole-thread print survived threads with collapsed messages.
