<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Decision records

*Why the app is the way it is. One file per decision, numbered, never edited into
agreement — a decision that changes gets a new record that supersedes the old one, and the
old one stays.*

## Index

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-xcode-project-in-git.md) | Check an Xcode project into git rather than ship a pure SwiftPM app | Accepted |
| [0002](0002-app-password-login-flow-v2.md) | Authenticate with an app password obtained through Login Flow v2 | Accepted |
| [0003](0003-local-first-full-mirror.md) | Keep a complete local mirror and read from it always | Accepted — supersedes `plan/macos-client.md` "No local database" |
| [0004](0004-grdb-over-swiftdata.md) | GRDB.swift over SwiftData | Accepted |
| [0005](0005-offline-mutation-queue.md) | Queue mutations locally and replay them | Accepted |
| [0006](0006-data-at-rest.md) | Sandbox container plus FileVault, not an encrypted database | Accepted, with a named trigger to revisit |
| [0007](0007-subscribed-mailboxes-only.md) | Mirror subscribed mailboxes only | Accepted |
| [0008](0008-no-automatic-eviction.md) | No automatic eviction; the user manages storage | Accepted |
| [0009](0009-sanitised-html-not-raw-mime.md) | Store the server's sanitised HTML, not raw MIME | Accepted |
| [0010](0010-webview-scheme-handler.md) | Serve body images through a custom URL scheme | Accepted |
| [0011](0011-fts5-standalone-index.md) | FTS5 table holding its own copy of the text | Accepted |
| [0012](0012-read-and-triage-scope.md) | v1 is read and triage; no composer | Accepted |
| [0013](0013-module-layout.md) | Four local packages plus one app target | Accepted |
| [0014](0014-singleton-enumeration.md) | Enumerate with `view=singleton`; thread locally | Accepted |
| [0015](0015-bounded-sync-window.md) | Bounded sync window plus periodic deep reconcile | Accepted |

## Which ones matter most

**0003** is the spine. The mirror is why the product is worth building and why most of the
other decisions look the way they do. **0015** is the one most likely to be got wrong by
someone who reads the sync endpoint's parameter names and assumes they mean what they
say. **0006** is the one most likely to be challenged, and the record says what would
change our minds.

## Format

```markdown
# ADR-NNNN: Short imperative title

**Status:** Proposed | Accepted | Superseded by ADR-MMMM
**Date:** YYYY-MM-DD
**Decided by:** who, and on what evidence

## Context
The forces. What is true that makes this a question at all.

## Decision
What we are doing, in the present tense.

## Consequences
What this buys, what it costs, and what it forecloses. Costs are not optional to write.

## Alternatives considered
Each with the reason it lost. "We did not think of it" is a valid reason and should be
written down as one.

## Revisit when
The concrete trigger that would reopen this.
```

## Adding one

Any agent that makes a decision another agent could reasonably have made differently
writes a record. Cheap test: if you had to think for more than a minute, or if you can
imagine a reviewer asking "why not X", it is a decision.

Number sequentially, add a row above, and link it from whichever architecture document it
governs. Do not edit an existing record to match new reality — write the new one and mark
the old **Superseded by**.
