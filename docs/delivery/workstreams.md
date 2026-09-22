<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Workstreams

*Sixteen units of work, each one an agent can be handed with its brief and left alone. The
dependency graph says what can run at once; the ownership table says what each may touch.*

Each workstream has a brief in [briefs/](briefs/) — that file is the prompt. Read this page
for the shape of the whole thing, then the brief for yours.

## Dependency graph

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

## The workstreams

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
