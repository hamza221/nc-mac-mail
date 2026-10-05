<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Workstreams

*Forty-five units of work: WS-00–WS-15 shipped v1; WS-16–WS-44 are v2. Each one an agent
can be handed with its brief and left alone. The dependency graph says what can run at
once; the ownership table says what each may touch.*

Each workstream has a brief in [briefs/](briefs/) — that file is the prompt. Read this page
for the shape of the whole thing, then the brief for yours.

## v1 dependency graph

```
WS-00  project skeleton, CI, lint
   │
   ├────────────┬──────────────┐
   ▼            ▼              ▼
WS-01 auth   WS-02 client   WS-03 store          ← wave 1, parallel
   │            │  models      │  schema, DAOs
   └────┬───────┴──────────────┘
        ▼
   WS-04 mirror/backfill ──▶ WS-05 sync ──▶ WS-06 offline queue   ← wave 2, in order
        │
        ├──────────────┬──────────────┬─────────────┐
        ▼              ▼              ▼             ▼
   WS-07 sidebar   WS-08 list    WS-09 message   WS-13 shell     ← wave 3, parallel
        │              │              │             │
        └──────────────┴──────┬───────┴─────────────┘
                              ▼
                      WS-10 triage ──▶ WS-11 search ──▶ WS-12 settings   ← wave 4
                              │
                              ▼
                      WS-14 test harness (starts in wave 1, lands continuously)
                      WS-15 feedback     (runs throughout, lands at the end)
```

WS-14 and WS-15 are not a phase. WS-14 provides the fake transport that wave 2 needs, so it
starts early; WS-15 is a standing obligation on everyone that one agent finally edits into
shape.

## v1 workstreams

| ID | Title | Depends on | Owns | Size |
| --- | --- | --- | --- | --- |
| [WS-00](briefs/WS-00-project-skeleton.md) | Project skeleton, packages, CI, lint | — | `NextcloudMail.xcodeproj`, all `Package.swift`, `.github/`, `Makefile`, `.swiftlint.yml`, `.swift-format` | M |
| [WS-01](briefs/WS-01-auth.md) | Login Flow v2, Keychain, session | WS-00 | `NCMailNet/Auth/**`, `NextcloudMail/Views/Login/**` | M |
| [WS-02](briefs/WS-02-http-client.md) | HTTP client, endpoints, models, decoding | WS-00 | `NCMailNet/Client/**`, `NCMailNet/Endpoints/**`, `NCMailCore/Models/**` | L |
| [WS-03](briefs/WS-03-store.md) | GRDB stack, schema, migrations, DAOs, FTS | WS-00 | `NCMailStore/**` | L |
| [WS-04](briefs/WS-04-mirror.md) | Mirror coordinator and two-stage backfill | 01,02,03 | `NCMailSync/Mirror/**` | L |
| [WS-05](briefs/WS-05-sync.md) | Incremental sync, tail scan, deep reconcile | WS-04 | `NCMailSync/Sync/**` | L |
| [WS-06](briefs/WS-06-offline-queue.md) | Mutation queue and drainer | WS-05 | `NCMailSync/Operations/**` | M |
| [WS-07](briefs/WS-07-sidebar.md) | Accounts and mailbox tree in the sidebar | WS-04 | `NextcloudMail/Views/Sidebar/**`, `NCMailCore/MailboxTree.swift` | M |
| [WS-08](briefs/WS-08-message-list.md) | Message list, threading, windowing | WS-04 | `NextcloudMail/Views/MessageList/**` | L |
| [WS-09](briefs/WS-09-message-view.md) | Message view, WebView, scheme handler | WS-04 | `NextcloudMail/Views/Message/**`, `NextcloudMail/WebView/**` | XL |
| [WS-10](briefs/WS-10-triage.md) | Triage actions, toolbar, shortcuts | 06,08,09 | `NextcloudMail/Actions/**`, `NextcloudMail/Commands/**` | M |
| [WS-11](briefs/WS-11-search.md) | Local full-text search | 03,08 | `NCMailStore/Search/**`, `NextcloudMail/Views/Search/**` | M |
| [WS-12](briefs/WS-12-settings.md) | Settings, storage panel, sign-out | 04,06 | `NextcloudMail/Views/Settings/**` | M |
| [WS-13](briefs/WS-13-app-shell.md) | App shell, theme, brand, restoration, status | 01,02 | `NextcloudMail/App/**`, `NextcloudMail/Theme/**`, `NextcloudMail/Status/**`, `NextcloudMail/MailSymbol.swift` | M |
| [WS-14](briefs/WS-14-test-harness.md) | Fake transport, fixtures, recorder, CI gates | WS-02 | `Packages/NCMailTestSupport/**`, `Scripts/record-fixtures.sh` | M |
| [WS-15](briefs/WS-15-feedback.md) | Library and server feedback, upstream reports | all | `docs/feedback/**` | S |

Sizes are relative, not estimates: S is under a day of focused work, M one to three, L a
week, XL more. WS-09 is XL because the WebView is where the unknowns are.

## v2 dependency graph

```
WAVE 1 (M8)  WS-16 API surface   WS-17 DAV + vCard/iCal   WS-18 store v2   WS-20 editor   WS-19 harness v2 (→ continuous)
                 │                     │                      │
WAVE 2 (M9)  WS-21 server-state mirror  WS-22 queue v2 + commands  WS-23 drafts/outbox engine  WS-24 contacts+calendars mirror
                 └──────────────┬──────────────┴───────────────┬────────────┘
                                ▼                              ▼
                         WS-25 app shell v2  (integrates every wave-2 engine)
                                │
WAVE 3 (M10–M11)  WS-26 people  WS-27 composer  WS-28 sidebar  WS-29 list  WS-30 message  WS-31 triage  WS-32 search  WS-33 Files
                                │
WAVE 4 (M12–M14)  WS-34 calendar  WS-35 contacts  WS-36 address books  WS-37 teams  WS-38 app settings  WS-39 account settings  WS-40 setup
                                │
WAVE 5 (M15)      WS-41 notifications/badge   WS-42 system integration
STANDING          WS-43 feedback v2 (∞)   WS-44 parity audit (lands last)
```

## v2 workstreams

| ID | Title | Depends on | Owns | Size |
| --- | --- | --- | --- | --- |
| [WS-16](briefs/WS-16-api-surface.md) | Mail API surface: endpoints, models, flag discovery | — | `NCMailNet/Endpoints/**`, `NCMailNet/Client/**`, `NCMailCore/Models/**` | L |
| [WS-17](briefs/WS-17-dav-and-formats.md) | DAV client, vCard and iCalendar | — | `NCMailNet/DAV/**`, `NCMailCore/Contacts/**`, `NCMailCore/Calendar/**` | L |
| [WS-18](briefs/WS-18-store-v2.md) | Store v2: migrations, DAOs, observations | — | `NCMailStore/**` except `Search/**` | XL |
| [WS-19](briefs/WS-19-test-harness-v2.md) | Test harness v2 | — | `Packages/NCMailTestSupport/**`, `Scripts/record-fixtures.sh` | M |
| [WS-20](briefs/WS-20-rich-text-editor.md) | Rich text editor | — | `NextcloudMail/Editor/**` | XL |
| [WS-21](briefs/WS-21-server-state-mirror.md) | Server-state mirror | 16, 18 | `NCMailSync/Sync/**`, `NCMailSync/Mirror/**` | L |
| [WS-22](briefs/WS-22-queue-v2-and-commands.md) | Queue v2 and settings commands | 16, 18 | `NCMailSync/Operations/**`, `NCMailSync/Commands/**` | L |
| [WS-23](briefs/WS-23-drafts-and-outbox.md) | Drafts and outbox engine | 16, 18 | `NCMailSync/Outbox/**` | L |
| [WS-24](briefs/WS-24-contacts-and-calendars-mirror.md) | Contacts and calendars mirror | 17, 18, 22 | `NCMailSync/Contacts/**`, `NCMailSync/Calendar/**` | XL |
| [WS-25](briefs/WS-25-app-shell-v2.md) | App shell v2 | 21, 22, 23, 24 | `NextcloudMail/App/**`, `Theme/**`, `Status/**`, `MailSymbol.swift` | M |
| [WS-26](briefs/WS-26-people.md) | People: recipient suggestions and contact cards | 24, 25 | `NextcloudMail/Views/People/**` | M |
| [WS-27](briefs/WS-27-composer.md) | Composer and outbox view | 20, 22, 23, 25, 26 | `NextcloudMail/Views/Composer/**`, `NextcloudMail/Views/Outbox/**` | XL |
| [WS-28](briefs/WS-28-sidebar-v2.md) | Sidebar and mailbox management | 21, 22, 25 | `NextcloudMail/Views/Sidebar/**`, `NCMailCore/MailboxTree.swift` | L |
| [WS-29](briefs/WS-29-message-list-v2.md) | Message list parity | 21, 22, 25 | `NextcloudMail/Views/MessageList/**` | L |
| [WS-30](briefs/WS-30-message-view-v2.md) | Message view parity | 21, 22, 25, 26 | `NextcloudMail/Views/Message/**`, `NextcloudMail/WebView/**` | XL |
| [WS-31](briefs/WS-31-triage-v2.md) | Triage parity: tags, snooze, quick actions, shortcuts | 22, 25 | `NextcloudMail/Actions/**`, `NextcloudMail/Commands/**` | L |
| [WS-32](briefs/WS-32-search-v2.md) | Search parity | 18, 25 | `NCMailStore/Search/**`, `NextcloudMail/Views/Search/**` | M |
| [WS-33](briefs/WS-33-files.md) | Files picker and Files actions | 17, 18, 25 | `NextcloudMail/Views/Files/**`, `NCMailSync/Files/**` | M |
| [WS-34](briefs/WS-34-calendar.md) | Calendar integration | 24, 30 | `NextcloudMail/Views/Calendar/**` | L |
| [WS-35](briefs/WS-35-contacts.md) | Contacts: browse, view, edit | 24, 25 | `NextcloudMail/Views/Contacts/**` except `AddressBooks/**`, `Teams/**` | XL |
| [WS-36](briefs/WS-36-address-books.md) | Address books, import/export, merge, batch | 35 | `NextcloudMail/Views/Contacts/AddressBooks/**` | L |
| [WS-37](briefs/WS-37-teams.md) | Teams, shared items, org chart | 35 | `NextcloudMail/Views/Contacts/Teams/**` | M |
| [WS-38](briefs/WS-38-app-settings.md) | App settings parity | 20, 21, 22 | `NextcloudMail/Views/Settings/**` except `Account/**` | L |
| [WS-39](briefs/WS-39-account-settings.md) | Account settings parity | 20, 21, 22 | `NextcloudMail/Views/Settings/Account/**` | XL |
| [WS-40](briefs/WS-40-account-setup.md) | Mail account setup | 22, 25 | `NextcloudMail/Views/AccountSetup/**` | L |
| [WS-41](briefs/WS-41-notifications.md) | Notifications, dock badge, Nextcloud notifications | 25 | `NextcloudMail/Notifications/**` | M |
| [WS-42](briefs/WS-42-system-integration.md) | System integration: default mail app, mailto, Spotlight, widgets, Share extension, Services | 25, 27 | `NextcloudMail.xcodeproj/**`, new extension target folders, `NextcloudMail/System/**` | L |
| [WS-43](briefs/WS-43-feedback-v2.md) | Feedback v2 | all | `docs/feedback/**` | S |
| [WS-44](briefs/WS-44-parity-audit.md) | Parity audit | all | `docs/product/parity.md` status column | M |

## File ownership

One rule: **an agent edits only what its workstream owns.** Anything else is a request to
the owner, or a note in the brief's report.

| Path | Owner |
| --- | --- |
| `NextcloudMail.xcodeproj/**` | **WS-00 only.** Every other workstream adds files inside packages, which needs no project edit |
| `Packages/*/Package.swift` | WS-00 (including `NCMailTestSupport`, which WS-14 then fills) |
| `Packages/NCMailCore/Sources/**` | WS-02, except `MailboxTree.swift` (WS-07) |
| `Packages/NCMailNet/Sources/Auth/**` | WS-01 |
| `Packages/NCMailNet/Sources/**` (rest) | WS-02 |
| `Packages/NCMailStore/Sources/**` | WS-03, except `Search/**` (WS-11) |
| `Packages/NCMailSync/Sources/Mirror/**` | WS-04 |
| `Packages/NCMailSync/Sources/Sync/**` | WS-05 |
| `Packages/NCMailSync/Sources/Operations/**` | WS-06 |
| `Packages/NCMailTestSupport/**` | WS-14 |
| `NextcloudMail/App/**`, `Theme/**`, `Status/**`, `MailSymbol.swift` | WS-13 |
| `NextcloudMail/Views/<Area>/**` | the workstream for that area |
| `docs/decisions/**` | anyone adding a record; never editing someone else's |
| `docs/feedback/**` | **append-only, by everyone.** WS-15 curates |
| `docs/architecture/**`, `docs/product/**` | the owning workstream, when reality diverges from the document |

A workstream that needs a change in someone else's file writes it in its report and, if it
blocks, raises it. It does not reach across the boundary — that is how two agents produce
one conflict and two half-fixes.

Two standing exceptions, both from WS-00. `NextcloudMail/App/NextcloudMailApp.swift` and
`RootSplitView.swift` exist so that the skeleton launches; they are WS-13's to replace, not
to work around. And `Packages/*/Tests/*/PlaceholderTests.swift` is an empty test target per
package, so the workstream that writes the first test writes a test rather than a target.

## v2 file ownership

The v1 table above still describes the rule; these are the deltas for v2:

- `NCMailCore/Sources/**` is owned by WS-16, except `Contacts/**` and `Calendar/**`
  (WS-17) and `MailboxTree.swift` (WS-28).
- `NCMailNet/Sources/Auth/**` stays with WS-01's code and has no v2 owner; any change is
  requested from WS-25.
- `NextcloudMail.xcodeproj/**` and `Package.swift` files are owned by WS-42. Any other
  workstream needing a manifest change requests it from WS-42. The one exception is WS-17
  and WS-24, which add no package because the folders already sit inside existing targets.

Standing exceptions (each is the only cross-boundary edit allowed):

1. WS-35 adds the single line embedding `ContactsSidebarSection` into
   `NextcloudMail/Views/Sidebar/SidebarView.swift`.
2. WS-27 adds the single line registering `ComposerScene()` in
   `NextcloudMail/App/NextcloudMailApp.swift`.
3. Any workstream may **append** cases to `MailSymbol.swift`; renaming or removing cases
   stays with WS-25.
4. Any workstream may **append** its own fixture files under `NCMailTestSupport`'s fixture
   directory, recorded with `Scripts/record-fixtures.sh`.

The report template and the working agreement below apply to v2 unchanged.

## What "owned" means for documents

Documents are not frozen. If an implementation finds that a document is wrong — the sync
endpoint behaves differently, a component does not compose, the schema needs a column —
**the document is updated in the same pull request as the code**, and the report says so.
A specification that drifts from the code is worse than none, because it is trusted.

What must not happen is a document quietly edited to match a shortcut. If the change is a
decision, it gets an ADR.

## Working agreement

**Branches.** One per workstream: `claude/ws-NN-short-slug`, off `main`.

**Commits.** Present tense, what and why. The what is in the diff; the why is not.

**Pull requests.** One per workstream, against `main`, titled `WS-NN: <title>`. The body
follows the template in the brief: what was built, what was decided, what surprised you,
what the next workstream needs to know.

**Review.** Every PR is reviewed against
[definition-of-done.md](definition-of-done.md) before merge. A green build is a
precondition, not a review.

**Blocked?** Do everything that is not blocked first. Then write the question in the PR
body with what you tried, and pick up the next unblocked workstream rather than idling.

## Report template

Every workstream ends with this in its PR body. It is how the next agent starts with
what you learned instead of rediscovering it.

```markdown
## WS-NN: <title>

### Built
<what exists now that did not before>

### Decisions
<ADRs added, or "none — nothing needed one">

### Surprises
<what the documents got wrong, what the server actually does, what took three tries>

### Library feedback
<what NextcloudUI made hard, or "nothing new" — appended to docs/feedback/library-feedback.md>

### For the next workstream
<what WS-MM needs to know before it starts>

### Verification
<commands run and their output, including the manual checks from the brief>
```
