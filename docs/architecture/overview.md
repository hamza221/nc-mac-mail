<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Architecture overview

*The module map, the dependency rules, and the one invariant everything else follows from.
Twenty minutes here saves a week of arguing later.*

## The invariant

> **The network never renders. The network only writes to the database.**

Views read the database. Sync writes the database. Nothing reads the network to put a
pixel on screen — not the list, not the message, not an avatar, not an inline image.

This is not a style preference; it is what makes the rest of the product true. Offline
reading, instant lists, local search, triage that survives a dead connection and a quit —
all of them are consequences of that one sentence. The moment a view can `await` a request,
every one of them becomes conditional.

Consequences worth stating, because they surprise people:

- **Opening a message that has not been backfilled yet does not fetch-and-show.** It
  raises that message's priority in the backfill queue, the fetch writes the database, and
  the view — which was already observing that row — updates. The difference is invisible
  to the user and total to the code.
- **There is no loading spinner on a list.** There is a mirror state, which is a property
  of the mailbox row in the database.
- **"Refresh" does not reload a view.** It nudges the sync engine.

## Modules

Five modules. Four are local Swift packages under `Packages/`; the fifth is the app target
in the Xcode project. A sixth package, `NCMailTestSupport`, holds the fake transport and the
recorded fixtures; it ships nothing and the app never depends on it. The split exists so that everything except the views is testable
without a GUI, and so that workstreams own directories rather than fighting over files.

The app embeds two extensions (WS-42, [ADR-0100](../decisions/0100-app-group-and-extension-targets.md)):
`NextcloudMailWidgets` (WidgetKit) and `NextcloudMailShare` (Share). Neither links a package
or opens the mirror; they exchange files with the app through the app group — the widget
snapshot ([ADR-0071](../decisions/0071-widgets-read-snapshot.md)) and the Share inbox — using
the few types in `NextcloudMailShared/`, which all three targets compile.

```
                    ┌───────────────────────┐
                    │  NextcloudMail (app)  │  SwiftUI, @Observable stores,
                    │  Xcode target         │  WKWebView, Settings, Commands
                    └───────────┬───────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
      │  NCMailSync  │─▶│ NCMailStore  │  │  NextcloudUI │  (external package)
      │              │  │              │  └──────────────┘
      │ mirror       │  │ GRDB stack   │
      │ backfill     │  │ schema       │
      │ sync loop    │  │ DAOs         │
      │ op queue     │  │ observation  │
      └──────┬───────┘  └──────┬───────┘
             │                 │
             ▼                 ▼
      ┌──────────────┐  ┌──────────────┐
      │  NCMailNet   │─▶│  NCMailCore  │
      │              │  │              │
      │ URLSession   │  │ value types  │
      │ auth         │  │ decoding     │
      │ endpoints    │  │ mailbox tree │
      │ login flow   │  │ pure logic   │
      └──────────────┘  └──────────────┘
```

| Module | Owns | Must not |
| --- | --- | --- |
| `NCMailCore` | Value types for every server payload, their `Decodable` conformances, the mailbox tree builder, thread grouping rules, the filter-string builder, pure formatting | Import `Foundation.URLSession`, GRDB, or SwiftUI |
| `NCMailNet` | `MailClient`, `LoginFlow`, `Keychain`, endpoint definitions, the error envelope, retry and backoff policy | Know that a database exists; know what a view is |
| `NCMailStore` | The GRDB stack, migrations, records, every query, the `StoreObservation` sequences, the storage-size accounting | Make a network request; contain product logic ("archive means move to…"); name a GRDB type in a public signature |
| `NCMailSync` | Mirror state machine, backfill scheduler, incremental sync, deep reconcile, the mutation queue and its drainer, conflict rules | Import SwiftUI; hold a reference to a view |
| `NextcloudMail` | Scenes, views, `@Observable` stores, the WKWebView host and scheme handler, keyboard commands, Settings | Make a network request outside `NCMailNet` (the one exception is the Sparkle updater, ADR-0108); read a JSON payload directly |

Dependencies point downward only. `NCMailStore` does not know `NCMailNet` exists; the sync
module is where the two meet. This is what makes "the network only writes to the database"
enforceable rather than aspirational: a store test cannot accidentally hit a server, and a
view has no type in scope that could.

The rule runs the other way too, and it is not free. `NCMailStore` owns GRDB, so no GRDB
type may appear in a signature the app or the sync engine can call — not as a return type,
not as a parameter, not as an enum payload. It went wrong once and cost the app its link
line ([ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md)); anything above
the store that needs the database needs a method on `MailStore`.

### Why packages instead of folders

Three reasons, in order of weight. A folder cannot enforce a dependency rule and a package
can. Tests for four fifths of the app then run under `swift test` with no simulator or
app-host, which is most of what CI does per commit. And a workstream can be handed a
package, which is a boundary an agent can respect, rather than "these files, mostly".

The cost is real: five `Package.swift` files, and the app target must be in the Xcode
project rather than a package ([ADR-0001](../decisions/0001-xcode-project-in-git.md)).
Accepted.

## Data flow

### Reading (the common path)

```
User selects a mailbox
        │
        ▼
MessageListStore sets its query   ──▶  NCMailStore.observeMessages(mailboxId:view:filter:)
        │                                       │
        │                              GRDB ValueObservation
        ▼                                       │
SwiftUI list renders  ◀─────────────────────────┘
```

No request was made. If the sync engine happens to write new rows a moment later, the
observation fires again and the list updates. The view does not know which of those two
things happened, which is the point.

### Writing (a triage action)

```
User presses A
        │
        ▼
MessageActions.archive(ids)
        │
        ├──▶  one write transaction:
        │        update message rows (mailboxId := archive)
        │        insert pendingOperation rows
        │
        ├──▶  list updates via observation (immediately)
        │
        └──▶  OperationDrainer wakes
                 │
                 ▼
             POST /api/messages/{id}/move
                 │
          success ──▶ delete the pendingOperation row
          gone    ──▶ delete the row and reconcile locally
          failure ──▶ backoff, retry, eventually surface
```

### Filling (the backfill)

```
MirrorCoordinator
   │
   ├── per account: GET /api/accounts, GET /api/mailboxes  ──▶ upsert
   │
   ├── per subscribed mailbox, stage 1:
   │       POST /api/mailboxes/{id}/sync {init:true}   (prime the server cache)
   │       GET  /api/messages?mailboxId=&view=singleton&limit=100&cursor=…
   │       …until a short page, writing envelopeCursor after every page
   │
   └── stage 2, newest first, bounded concurrency:
           GET /api/messages/{id}/body
           GET /api/messages/{id}/html?plain=true
           ──▶ messageBody + attachment + messageSearch rows
```

Both stages are resumable because their progress is a column, not a variable. Full detail
in [local-mirror.md](local-mirror.md).

## Where things run

See [concurrency.md](concurrency.md) for the rules. The short version:

- The app target is compiled with `defaultIsolation(MainActor.self)`, matching
  `NextcloudUI`. Views and stores are main-actor by default and say nothing about it.
- `NCMailStore` is not main-actor. Writes go through a GRDB `DatabaseQueue`; reads for the
  UI arrive as `ValueObservation` on the main actor.
- `NCMailSync` is a set of actors that each own their state and talk to each other with
  messages, not locks. `AccountEngine` (app target) is the only place one is started, at two
  levels: per Nextcloud login `CalendarListSync`, `ContactsSync`, `ServerResultFetcher` and
  `ServerStateMirror`; then per mail account row `MirrorCoordinator`, `SyncScheduler` (with
  its `OperationDrainer`), `AvatarFetcher` and `OutboxSender`. Sign-out stops them in reverse
  ([ADR-0084](../decisions/0084-the-shell-starts-logins-before-accounts.md));
  `SettingsCommands` is built per use, never running.
- `NCMailNet` is stateless and `Sendable`; the client is a value type.

## Choices that shaped this, with their records

| Choice | Record |
| --- | --- |
| Xcode project in git, not a pure SwiftPM app | [ADR-0001](../decisions/0001-xcode-project-in-git.md) |
| App password over Login Flow v2 | [ADR-0002](../decisions/0002-app-password-login-flow-v2.md) |
| Local-first full mirror (reverses `plan/macos-client.md`) | [ADR-0003](../decisions/0003-local-first-full-mirror.md) |
| GRDB over SwiftData | [ADR-0004](../decisions/0004-grdb-over-swiftdata.md) |
| Offline mutation queue | [ADR-0005](../decisions/0005-offline-mutation-queue.md) |
| Sandbox + FileVault rather than an encrypted database | [ADR-0006](../decisions/0006-data-at-rest.md) |
| Mirror subscribed mailboxes only | [ADR-0007](../decisions/0007-subscribed-mailboxes-only.md) |
| No automatic eviction | [ADR-0008](../decisions/0008-no-automatic-eviction.md) |
| Store the server's sanitised HTML, not raw MIME | [ADR-0009](../decisions/0009-sanitised-html-not-raw-mime.md) |
| A custom URL scheme for images in the WebView | [ADR-0010](../decisions/0010-webview-scheme-handler.md) |
| FTS5 with its own copy of the text | [ADR-0011](../decisions/0011-fts5-standalone-index.md) |
| Read and triage only in v1 | [ADR-0012](../decisions/0012-read-and-triage-scope.md) |
| Five packages, one app target | [ADR-0013](../decisions/0013-module-layout.md) |
| Enumerate with `view=singleton`, thread locally | [ADR-0014](../decisions/0014-singleton-enumeration.md) |
| Bounded sync window plus deep reconcile | [ADR-0015](../decisions/0015-bounded-sync-window.md) |
| Local ids, with the server's kept as `remoteId` | [ADR-0033](../decisions/0033-accounts-have-a-local-identity.md) |
| The store's own `AsyncSequence`, and no GRDB in its public API | [ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md) |
| A login's engines start before its accounts', stop after them | [ADR-0084](../decisions/0084-the-shell-starts-logins-before-accounts.md) |
