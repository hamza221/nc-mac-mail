<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-43 — Feedback v2

**Runs throughout. Lands at the end. Size: S.**

## Goal

The same job as WS-15, for v2: everything every v2 workstream learned, curated into
documents the library maintainer and the Mail server team can act on.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [ADR-0003](../../decisions/0003-local-first-full-mirror.md)
- [ADR-0064](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [WS-15-feedback.md](WS-15-feedback.md) — the shape of the job, unchanged
- [../../feedback/library-feedback.md](../../feedback/library-feedback.md),
  [../../feedback/server-findings.md](../../feedback/server-findings.md),
  [../../feedback/upstream-issues.md](../../feedback/upstream-issues.md) — what is already there
- Every merged v2 workstream's pull request report

## You own

`docs/feedback/**`

## Build

- Same job as WS-15 for v2: curate `library-feedback.md`, `server-findings.md` and
  `upstream-issues.md` from every v2 workstream's report; the standing obligation on
  everyone else to append as they go is unchanged, and a report that says "nothing new"
  over a diff containing a workaround gets asked about.
- Additionally: the `NCRichContenteditable` proposal from WS-20 — the editor is designed
  to be upstreamed to NextcloudUI (ADR-0065), and the proposal is this workstream's
  deliverable to curate.

## Acceptance

- Every merged v2 workstream's report is represented, or explicitly considered and left
  out with a reason.
- The `NCRichContenteditable` proposal is in the upstream drafts, postable without editing.

## Out of scope

Changing either upstream repository. Making the library changes ourselves. Auditing the
parity matrix (WS-44).

## Report

The pull request body **is** the summary, as for WS-15: what `NextcloudUI` should change
before freezing its API, and what Nextcloud Mail should add for native clients.
