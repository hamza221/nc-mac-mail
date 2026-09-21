<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0013: Four local packages plus one app target

*(plus a fifth, test-only, that ships nothing — see below)*

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture, to make the dependency rules enforceable and the work parallel

## Context

`plan/macos-client.md` sketched a single app target with folders — right for the client it
described, which had no storage layer. With [ADR-0003](0003-local-first-full-mirror.md) the
app grows a storage layer, a sync engine and a mutation queue: three subsystems that are
pure logic, must not touch the UI, and must be testable without one.

There is also an orchestration problem. Several agents implement this in parallel, and a
folder is not a boundary anyone can enforce.

## Decision

```
NextcloudMail.xcodeproj          the app target: SwiftUI, WKWebView, Settings
Packages/
  NCMailCore/                    value types, decoding, mailbox tree, pure logic
  NCMailNet/                     URLSession, auth, endpoints          → Core
  NCMailStore/                   GRDB, schema, queries, observation   → Core
  NCMailSync/                    mirror, sync, mutation queue         → Core, Net, Store
  NCMailTestSupport/             fake transport, fixtures, seeding (test-only)
```

`NCMailTestSupport` is a fifth package only in the mechanical sense: it ships nothing, the
app target never depends on it, and it exists because a SwiftPM test target cannot reference
files outside its own package — the recorded fixtures have to live somewhere every package's
tests can reach.

Dependencies point downward only. `NCMailStore` cannot see `NCMailNet`; the sync module is
where they meet. Isolation settings differ per module — see
[../architecture/concurrency.md](../architecture/concurrency.md).

## Consequences

- "The network only writes to the database" is enforced by the compiler, not by review: a
  store test has no HTTP type in scope, and a view has no `URLSession`.
- Four fifths of the app tests under `swift test`, with no Xcode, no app host, no simulator.
  CI is fast for most commits.
- A workstream can own a package. `Packages/NCMailStore/**` is a boundary an agent can be
  told to stay inside, which is what the file-ownership table in
  [../delivery/workstreams.md](../delivery/workstreams.md) is built on.
- Four `Package.swift` files to keep in step; WS-00 owns them and their settings.
- The app target still lives in the Xcode project ([ADR-0001](0001-xcode-project-in-git.md)),
  so `project.pbxproj` remains a conflict surface — which is why only WS-00 edits it.
- Adding a file to a package needs no project edit at all, which is most additions.

## Alternatives considered

**One app target with folders.** Simplest, and unenforceable: nothing stops a view from
importing GRDB, and nothing runs without Xcode.

**One local package containing everything non-UI.** Fewer manifests, and the internal
dependency rules go back to being conventions.

**Publish the packages as separate repositories.** Version skew and a release process, for
code with exactly one consumer.

## Revisit when

A package stops having a clear owner, or the manifests start to disagree with each other
more than once a month.
