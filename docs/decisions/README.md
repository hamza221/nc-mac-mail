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
| [0016](0016-warnings-as-errors-at-the-build-command.md) | Ask for warnings-as-errors at the build command, not in the manifests | Accepted |
| [0017](0017-file-system-synchronized-group.md) | The app target reads its sources from a synchronised folder | Accepted |
| [0018](0018-ad-hoc-signature-in-the-checked-in-project.md) | The checked-in project signs ad hoc | Accepted |
| [0019](0019-login-flow-verifies-the-mail-app.md) | `LoginFlow` proves the Mail app exists before reporting success | Accepted |
| [0020](0020-raw-json-in-a-wrapper.md) | Carry the server's JSON in a `RawBacked` wrapper, not in every model | Accepted |
| [0021](0021-one-message-flags-type.md) | One `MessageFlags` type for the envelope and the body | Accepted |
| [0022](0022-fixtures-by-path-not-bundle.md) | Tests read fixtures by path, not through `Bundle.module` | Superseded by ADR-0026 for `NCMailCoreTests`/`NCMailStoreTests`; still Accepted for `NCMailNetTests` |
| [0023](0023-store-records-are-not-wire-models.md) | Store records are their own types, and a write is narrower than a row | Accepted |
| [0024](0024-fts-deletes-in-a-trigger.md) | Delete the search index row from a trigger, not from Swift | Accepted |
| [0025](0025-rowid-tables-for-anything-observed.md) | Only unobserved tables may be `WITHOUT ROWID` | Accepted |
| [0026](0026-fixtures-through-a-dependency-free-target.md) | Fixtures through a dependency-free `NCMailFixtures` target | Accepted |
| [0027](0027-userdefaults-cache-for-the-launch-theme.md) | Cache the launch theme colour in `UserDefaults` for boot, `meta` for everything else | Accepted |
| [0028](0028-no-force-unwrap-even-in-tests.md) | No force unwrap anywhere, including tests — `#require` instead | Accepted |
| [0029](0029-app-test-target-borrows-its-modules-from-the-host.md) | The app's test target borrows its modules from the host app | Accepted |
| [0030](0030-stage-one-owns-its-cursor.md) | Stage 1 owns its cursor — envelopes commit first, and priming never moves it | Accepted |
| [0031](0031-conditions-pushed-power-read.md) | The app pushes the network path into the mirror; the mirror reads the power state itself | Accepted |
| [0032](0032-body-text-is-not-kept-twice.md) | `messageBody.rawJSON` drops the `body` field | Accepted — narrows ADR-0020 |

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
