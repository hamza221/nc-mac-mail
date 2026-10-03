<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-12 — Settings, storage panel, sign-out

**Wave 4, after WS-04 and WS-06. Size: M.**

## Goal

The controls [ADR-0008](../../decisions/0008-no-automatic-eviction.md) promises: the user
can see exactly what the mirror is using and decide what happens to it.

## Before you start

- [../../decisions/0008-no-automatic-eviction.md](../../decisions/0008-no-automatic-eviction.md)
- [../../product/ux-spec.md](../../product/ux-spec.md) — settings section
- [../../architecture/local-mirror.md](../../architecture/local-mirror.md) — storage accounting
- [../../product/user-stories.md](../../product/user-stories.md) — S-08

## You own

`NextcloudMail/Views/Settings/**`

## Build

A `Settings` scene, `Form` + `.formStyle(.grouped)` — the library deliberately does not wrap
this and its DocC says why. Three tabs.

**General** — default list view (threaded/flat), mark-as-read delay (immediately / after n
seconds / manually), a note about appearance following the system.

**Accounts** — one row per account: name, address, mirror state, last sync, Sign out. A
line saying accounts are added in the web client, with a button that opens it. A blank space
where account creation should be is worse than an explanation.

**Storage** — the panel that matters:

```
Work · lorelai@dragonfly.example
  48,902 messages · 812 MB local · mirror complete
  [Remove local copies]  [Re-download]  [Check for missing messages]

Personal · lorelai@example.com
  3,204 messages · 61 MB local · downloading bodies (2,104 remaining)   [Pause]
```

- Size from `sum(byteSize)` plus the file size on disk. Do not shell out to `du`.
- **Remove local copies** — bodies, inline image blobs and FTS rows for that account;
  envelopes kept; `VACUUM`; the app keeps working and bodies re-fetch on open.
- **Re-download** — the same, plus `bodyState = 'missing'`, which restarts stage 2.
- **Check for missing messages** — triggers WS-05's deep reconcile with visible progress.
- **Pause** persists across launches.

**Every destructive confirmation says, in those words, that it removes local copies only
and does not touch mail on the server.** That sentence is the whole reason the control gets
used; without it nobody dares press it.

**Sign out** — offers keep or remove local copies, and if the operation queue is non-empty,
asks Send now / Discard / Cancel first ([WS-06](WS-06-offline-queue.md)).

## Acceptance

- Sizes match reality within a few percent — check against Finder.
- Remove local copies leaves the app working: lists fine, messages re-fetch, search says
  what it can now cover.
- Re-download restarts the backfill from zero bodies without touching envelopes.
- Pause survives a relaunch.
- Every destructive action is confirmed, and every confirmation carries the local-copies-only
  sentence.
- Sign out with a queued action asks first and honours the answer.
- `VACUUM` on a 4 GB database does not hang the UI — it runs off the main actor with
  progress.

## Out of scope

Account creation, server settings, aliases, signatures, Sieve — all web-client or post-v1.
Backfill mechanics (WS-04); reconcile (WS-05).

## Report

Additionally: what `VACUUM` costs on a large database, and whether the storage numbers were
easy to compute accurately or needed a different accounting than
[../../architecture/local-mirror.md](../../architecture/local-mirror.md) assumes.
