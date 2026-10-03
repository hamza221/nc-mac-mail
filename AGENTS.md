<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Working in this repository

*Read this before your brief. It is short on purpose.*

## What this repository is

A native macOS client for Nextcloud Mail. The specification is in `docs/` and the original
briefs are in `plan/`. v1 (WS-00–WS-15) has shipped: read and triage over a full local
mirror. Build commands and the two toolchain traps are in the README's development section.

v2 (WS-16–WS-44) is parity with the Nextcloud Mail web client plus Contacts; see
`docs/delivery/roadmap.md`. Yours has a brief in
`docs/delivery/briefs/WS-NN-*.md`. That brief is your instructions; this file is the house
rules.

## The one invariant

> **The network never renders. The network only writes to the database.**

Views read the database. Sync writes the database. No view, store or component reaches for
`URLSession`. Offline reading, instant lists, local search and triage-on-a-train are all
consequences of that one sentence, and every one of them breaks the moment a view can
`await` a request.

If you believe your workstream is the exception, you have found something the design got
wrong. Say so in your report — do not quietly special-case it.

## Before you write anything

1. `docs/architecture/overview.md` — twenty minutes, and the rest makes sense.
2. `docs/decisions/0003-local-first-full-mirror.md` — the decision everything hangs off.
3. Your brief, and the documents it names.
4. `docs/delivery/definition-of-done.md` — the gate. Read it at the start, not at the end.

## Rules

**Stay inside what you own.** The ownership table is in `docs/delivery/workstreams.md`.
Need a change elsewhere? Write it in your report. Do not reach across — that is how two
agents produce one conflict and two half-fixes.

**Fix documents that turn out to be wrong, in the same pull request as the code.** The
specification was written from reading `nextcloud/mail` and `nextcloud-swiftui`, not from
running against a live server. Where reality differs, reality wins and the document gets
corrected. A specification that drifts is worse than none, because it is trusted.

**Write an ADR for any decision someone could reasonably have made differently.** Cheap
test: if you thought about it for more than a minute, or you can imagine a reviewer asking
"why not X", it is a decision. Format and numbering in `docs/decisions/README.md`.

**Append to `docs/feedback/library-feedback.md`.** Every workstream. If `NextcloudUI` made
something awkward, that is not friction to absorb silently — it is the second deliverable
of this whole project. "Nothing new" is an acceptable answer only if it is true.

**Fixtures come from a real server.** Never hand-write a JSON fixture: it tests that the
decoder matches your idea of the payload, which is the thing most likely to be wrong.
`Scripts/record-fixtures.sh`.

**Measure before optimising, and write the number down.** "Fast enough" is not a finding.

## Style

Swift 6, strict concurrency, warnings as errors. No `@unchecked Sendable`. No `print` —
`OSLog`, with `.private` on anything that could carry user data. No force unwraps outside
tests unless a comment proves the invariant. No hard-coded colours, spacing or radii:
`theme.colors`, `theme.metrics`. No `Image(systemName:)` outside `MailSymbol.swift`.

Comments explain **why**. The diff already shows what.

## Git

Branch `claude/ws-NN-short-slug` off `main`. One pull request per workstream, titled
`WS-NN: <title>`, body following the report template in `docs/delivery/workstreams.md`.

## Blocked?

Do everything that is not blocked. Then put the question in your pull request body with
what you tried, and pick up the next unblocked workstream rather than idling.

## Security

You are handling other people's mail.

- No credential, token, subject, address or body in any log, at any level.
- No network call outside `NCMailNet`.
- The WebView rules in `docs/architecture/rendering.md` are not suggestions; if you touch
  it, walk checkpoint 2 in `docs/architecture/security.md` line by line.
