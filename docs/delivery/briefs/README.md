<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Agent briefs

*One file per workstream. Each is a prompt: hand it to an agent, unedited, and it has
everything it needs except a Nextcloud instance to test against.*

Every brief has the same shape:

| Section | What it is for |
| --- | --- |
| **Goal** | One sentence. If the work does not serve this, it is out of scope |
| **Before you start** | The exact documents to read, in order. Not "read the docs" |
| **You own** | The only paths this workstream may edit |
| **Build** | Deliverables, with paths and the signatures that other workstreams will call |
| **Acceptance** | What must be demonstrably true. Checked at review |
| **Out of scope** | What to leave alone, and who owns it instead |
| **Report** | What the pull request body must contain beyond the standard template |

| Brief | Workstream | Wave |
| --- | --- | --- |
| [WS-00](WS-00-project-skeleton.md) | Project skeleton, packages, CI, lint | 0 |
| [WS-01](WS-01-auth.md) | Login Flow v2, Keychain, session | 1 |
| [WS-02](WS-02-http-client.md) | HTTP client, endpoints, models, decoding | 1 |
| [WS-03](WS-03-store.md) | GRDB stack, schema, migrations, DAOs | 1 |
| [WS-04](WS-04-mirror.md) | Mirror coordinator and backfill | 2 |
| [WS-05](WS-05-sync.md) | Incremental sync and reconcile | 2 |
| [WS-06](WS-06-offline-queue.md) | Mutation queue and drainer | 2 |
| [WS-07](WS-07-sidebar.md) | Sidebar | 3 |
| [WS-08](WS-08-message-list.md) | Message list | 3 |
| [WS-09](WS-09-message-view.md) | Message view and WebView | 3 |
| [WS-10](WS-10-triage.md) | Triage actions and shortcuts | 4 |
| [WS-11](WS-11-search.md) | Local full-text search | 4 |
| [WS-12](WS-12-settings.md) | Settings and storage | 4 |
| [WS-13](WS-13-app-shell.md) | App shell, theme, restoration | 3 |
| [WS-14](WS-14-test-harness.md) | Fake transport, fixtures, CI | 1→ |
| [WS-15](WS-15-feedback.md) | Library and server feedback | ∞ |

## Rules that apply to every brief

1. **The network never renders. The network only writes to the database.** A view that
   makes a request is a bug, whatever it makes it faster.
2. **Stay inside what you own.** Need something elsewhere? Write it in your report.
3. **A document that turns out to be wrong gets fixed in your pull request.** Silence is
   how a specification rots.
4. **A decision someone could reasonably have made differently gets an ADR.**
5. **Every workstream appends to [../../feedback/library-feedback.md](../../feedback/library-feedback.md)**
   or says "nothing new" and means it.
6. **[../definition-of-done.md](../definition-of-done.md) is the gate.** Read it before you
   start, not when you think you are finished.
