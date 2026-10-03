<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Documentation map

Every document has one job and says so in its first line. If you cannot tell which file a
new fact belongs in, it probably belongs in a decision record.

## Product — what we are building and why

| File | Answers |
| --- | --- |
| [product/overview.md](product/overview.md) | What the app is, who it is for, what v1 includes and what it deliberately does not |
| [product/parity.md](product/parity.md) | Every user-facing behaviour of the Nextcloud Mail web client and Nextcloud Contacts, mapped to the workstream that delivers it or the ADR that excludes it |
| [product/user-stories.md](product/user-stories.md) | The flows, each with acceptance criteria an agent can test against |
| [product/ux-spec.md](product/ux-spec.md) | Screen by screen: layout, states, empty states, errors, the keyboard map |

## Architecture — how it is built

| File | Answers |
| --- | --- |
| [architecture/overview.md](architecture/overview.md) | Module map, dependency rules, data flow, the one invariant |
| [architecture/local-mirror.md](architecture/local-mirror.md) | The cache: what is stored, the backfill state machine, resumability, storage management |
| [architecture/sync-engine.md](architecture/sync-engine.md) | Incremental sync, the server's sync semantics and their traps, deep reconciliation |
| [architecture/offline-queue.md](architecture/offline-queue.md) | Optimistic mutation, the operation log, draining, conflicts, failure surfacing |
| [architecture/networking.md](architecture/networking.md) | Auth, the HTTP client, error envelopes, retry and rate-limit etiquette |
| [architecture/rendering.md](architecture/rendering.md) | Message bodies: WKWebView, blocked content, `cid:` and proxied images, dark mode |
| [architecture/concurrency.md](architecture/concurrency.md) | Swift 6 isolation, actors, where work runs, how views observe the database |
| [architecture/security.md](architecture/security.md) | Threat model, credential handling, data at rest, HTML safety, what we do not defend against |

## Decisions — why it is built that way

[decisions/README.md](decisions/README.md) indexes all of them and explains how to add one.
Records from ADR-0001 on; the index lists their status. Read ADR-0003 first; most of the rest hang off it.

## Reference — the facts you will look up repeatedly

| File | Answers |
| --- | --- |
| [reference/api-payloads.md](reference/api-payloads.md) | Exact JSON shapes and endpoint semantics, cited to `nextcloud/mail` source lines, including the four traps |
| [reference/schema.sql](reference/schema.sql) | The canonical local schema. The migration must reproduce it exactly |
| [reference/ui-components.md](reference/ui-components.md) | Every `NextcloudUI` component this app uses, with real signatures, and the gaps we have to fill ourselves |
| [reference/glossary.md](reference/glossary.md) | `databaseId` vs `id`, envelope vs message vs body vs thread, mailbox vs folder |
| [reference/server-flags.md](reference/server-flags.md) | Written by WS-16 |

Plus [plan/API.md](../plan/API.md), the complete endpoint map — still accurate, still the
first place to look for an endpoint this app does not use yet.

## Delivery — who does what, in what order

| File | Answers |
| --- | --- |
| [delivery/roadmap.md](delivery/roadmap.md) | Milestones M0–M16, each with an exit criterion you can demonstrate |
| [delivery/v2-roadmap-plan.md](delivery/v2-roadmap-plan.md) | The v2 plan: parity with the Nextcloud Mail web client plus Contacts — ADRs, parity matrix, milestones M8–M16, workstreams WS-16–WS-44 |
| [delivery/workstreams.md](delivery/workstreams.md) | v1's 16 and v2's 29 workstreams, their dependencies, and the file ownership that keeps agents out of each other's way |
| [delivery/briefs/](delivery/briefs/) | One ready-to-assign brief per workstream. This is the "mapped to other agents" part |
| [delivery/definition-of-done.md](delivery/definition-of-done.md) | The gates. No workstream is finished without all of them |
| [delivery/testing-strategy.md](delivery/testing-strategy.md) | What we test, where, and how to record fixtures from a real server |

## Feedback — what this exercise is for

| File | Answers |
| --- | --- |
| [feedback/library-feedback.md](feedback/library-feedback.md) | Running list of everywhere `NextcloudUI` needed a workaround. The deliverable its README is waiting for |
| [feedback/server-findings.md](feedback/server-findings.md) | Things found in `nextcloud/mail` worth raising upstream |
| [feedback/upstream-issues.md](feedback/upstream-issues.md) | The issue text itself, ready for a human to post. Written by WS-15 from the two files above |

The first two are append-only during implementation, and WS-15 curated them at the end. A
workstream that touched the library or the server API and added nothing to them has probably
not finished.

## Reading order for a new agent

1. [AGENTS.md](../AGENTS.md) — the rules of the repo.
2. [architecture/overview.md](architecture/overview.md) — twenty minutes, and the rest makes sense.
3. [decisions/0003-local-first-full-mirror.md](decisions/0003-local-first-full-mirror.md) — the decision the design is organised around.
4. Your brief in [delivery/briefs/](delivery/briefs/), which names everything else you need.
