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
| [WS-16](WS-16-api-surface.md) | Mail API surface: endpoints, models, flag discovery | 1 |
| [WS-17](WS-17-dav-and-formats.md) | DAV client, vCard and iCalendar | 1 |
| [WS-18](WS-18-store-v2.md) | Store v2: migrations, DAOs, observations | 1 |
| [WS-19](WS-19-test-harness-v2.md) | Test harness v2 | 1 |
| [WS-20](WS-20-rich-text-editor.md) | Rich text editor | 1 |
| [WS-21](WS-21-server-state-mirror.md) | Server-state mirror | 2 |
| [WS-22](WS-22-queue-v2-and-commands.md) | Queue v2 and settings commands | 2 |
| [WS-23](WS-23-drafts-and-outbox.md) | Drafts and outbox engine | 2 |
| [WS-24](WS-24-contacts-and-calendars-mirror.md) | Contacts and calendars mirror | 2 |
| [WS-25](WS-25-app-shell-v2.md) | App shell v2 | 2 |
| [WS-26](WS-26-people.md) | People: recipient suggestions and contact cards | 3 |
| [WS-27](WS-27-composer.md) | Composer and outbox view | 3 |
| [WS-28](WS-28-sidebar-v2.md) | Sidebar and mailbox management | 3 |
| [WS-29](WS-29-message-list-v2.md) | Message list parity | 3 |
| [WS-30](WS-30-message-view-v2.md) | Message view parity | 3 |
| [WS-31](WS-31-triage-v2.md) | Triage parity: tags, snooze, quick actions, shortcuts | 3 |
| [WS-32](WS-32-search-v2.md) | Search parity | 3 |
| [WS-33](WS-33-files.md) | Files picker and Files actions | 3 |
| [WS-34](WS-34-calendar.md) | Calendar integration | 4 |
| [WS-35](WS-35-contacts.md) | Contacts: browse, view, edit | 4 |
| [WS-36](WS-36-address-books.md) | Address books, import/export, merge, batch | 4 |
| [WS-37](WS-37-teams.md) | Teams, shared items, org chart | 4 |
| [WS-38](WS-38-app-settings.md) | App settings parity | 4 |
| [WS-39](WS-39-account-settings.md) | Account settings parity | 4 |
| [WS-40](WS-40-account-setup.md) | Mail account setup | 4 |
| [WS-41](WS-41-notifications.md) | Notifications, dock badge, Nextcloud notifications | 5 |
| [WS-42](WS-42-system-integration.md) | System integration: default mail app, mailto, Spotlight, widgets, Share extension, Services | 5 |
| [WS-43](WS-43-feedback-v2.md) | Feedback v2 | ∞ |
| [WS-44](WS-44-parity-audit.md) | Parity audit | end |

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
7. **Server-computed results are rows** (ADR-0067); **server-validated settings are commands**
   (ADR-0068).
