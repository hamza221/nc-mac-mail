<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0044: The queue type is `MutationQueue`, not `OperationQueue`

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-06, on a compiler error

## Context

[WS-06's brief](../delivery/briefs/WS-06-offline-queue.md) specifies `public actor
OperationQueue`. Foundation has exported `OperationQueue` since 1994, and every caller of this
one will be a SwiftUI file or a view model that imports Foundation transitively. The first
test file that imported both said so:

```
error: 'OperationQueue' is ambiguous for type lookup in this context
```

WS-10 (triage actions), WS-12 (settings and sign-out) and WS-13 (the sidebar footer) are all
callers. Every one of them would have to write `NCMailSync.OperationQueue` at every mention,
or add a `typealias` per file, for as long as the type exists.

## Decision

The actor is `MutationQueue`, and its configuration is `MutationQueueConfiguration`.

`OperationDrainer`, `OperationKind`, `OperationStoring`, `OperationError` and the
`Operations/**` folder keep their names: none of them collides with anything, and
`OperationDraining` is already shipped in `Sync/**` and named in ADR-0037.

The vocabulary is the documents' own. [ADR-0005](0005-offline-mutation-queue.md) is "Queue
mutations locally and replay them" and [offline-queue.md](../architecture/offline-queue.md)
is "the offline mutation queue", so `MutationQueue` is what both of them already call it in
prose.

## Consequences

- No caller writes a module prefix, and nobody shadows a Foundation type by accident.
- The brief and `offline-queue.md` say `OperationQueue` in a code block. Both are corrected in
  the same pull request, which is `CLAUDE.md`'s rule for a document reality disagrees with.
- The two halves of the queue are named on different nouns — `MutationQueue` and
  `OperationDrainer`. That is the cost, and it is smaller than the alternative.

## Alternatives considered

**Keep `OperationQueue` and let callers disambiguate.** `NCMailSync.OperationQueue` at every
mention, in three workstreams that have not started yet, for a name nobody prefers.

**Rename everything to `Mutation…`.** `OperationDraining` is public, shipped in WS-05, and
named in an accepted ADR; renaming it to match would touch another workstream's file to fix a
problem it does not have.

**`TriageQueue`.** Accurate today and wrong the moment a queued send arrives, which
ADR-0005's "Revisit when" already anticipates.

## Revisit when

Never, unless Foundation's `OperationQueue` is retired.
