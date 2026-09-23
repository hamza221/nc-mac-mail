<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-06 — Mutation queue and drainer

**Wave 2, after WS-05. Size: M.**

## Goal

Every triage action lands locally at once and reaches the server eventually — including
actions taken on a train, quit, relaunched, and reconnected three days later.

## Before you start

- [../../architecture/offline-queue.md](../../architecture/offline-queue.md) — **all of it**
- [../../decisions/0005-offline-mutation-queue.md](../../decisions/0005-offline-mutation-queue.md)
- [../../architecture/sync-engine.md](../../architecture/sync-engine.md) — ordering and conflicts
- [../../product/user-stories.md](../../product/user-stories.md) — S-05, S-06

## You own

`Packages/NCMailSync/Sources/NCMailSync/Operations/**`

## Build

*As built, two names differ from this sketch and one method was added. The actor is
`MutationQueue`, because `OperationQueue` is Foundation's
([ADR-0044](../../decisions/0044-the-queue-type-is-not-called-operationqueue.md)); its
storage was the `OperationStoring` protocol rather than `MailStore`, because the store had
no queue DAO ([ADR-0043](../../decisions/0043-the-queue-names-the-storage-it-needs.md)) —
that DAO landed as `Queries/MailStore+Operations.swift` and the protocol is gone
([ADR-0045](../../decisions/0045-the-store-grows-the-queue-dao-and-the-readers.md)); and
`MutationQueue.localMailboxId(for:accountId:)` exists because `account.archiveMailboxId`
turned out to be the server's id, not the mirror's.*

```swift
public enum MailOperation: Sendable {
    case setFlags(messageIds: [Int64], flags: [String: Bool])
    case move(messageIds: [Int64], destinationMailboxId: Int64)
    case delete(messageIds: [Int64])
    case junk(messageIds: [Int64], junkMailboxId: Int64)
    case moveThread(rootId: String, destinationMailboxId: Int64)
    case deleteThread(rootId: String)
}

public actor OperationQueue {
    /// Applies locally and enqueues, in ONE transaction. Both or neither.
    public func perform(_ operation: MailOperation, accountId: Int64) async throws
}

public actor OperationDrainer {
    public func drain() async          // one in flight per account, in id order
    public func retryAll() async
    public func discard(operationId: Int64) async   // reverts the local change too
    public var pendingCount: AsyncStream<PendingSummary> { get }
}
```

**The transaction rule** is the whole workstream:

```swift
try await store.enqueue(rows, applying: effects)
drainer.wake()
```

Nothing in between, no `await` between applying and inserting, no optimistic-then-queue.
`MailStore.write` is internal since ADR-0034, so the transaction lives behind
`MailStore.enqueue(_:applying:)`; the guarantee is the same one.

**Payloads are absolute intent** — `{"seen": true}`, never a toggle — so replay is
idempotent and collapsing is well defined.

**Collapsing**, inside the transaction that picks the work: consecutive `setFlags` on the
same message merge; `move` then `move` keeps the last; anything then `delete` becomes the
delete; different messages never collapse and their order is preserved.

**Drain outcomes** exactly as in the architecture document: 2xx delete the row; 404/410
delete the row and the local message; 403 refresh the account; 409/412 force a sync and let
the server win; 429/503 honour `Retry-After` without counting a failure; 5xx and offline
back off 2/8/30/120/600 seconds then every ten minutes.

**Parameter trap:** `POST /api/messages/{id}/move` takes `destFolderId`;
`POST /api/thread/{id}` takes `destMailboxId`. Same concept, two names.

**Archive is not an operation kind** — it is `move` to `account.archiveMailboxId`, resolved
from the account that owns the **message**, never the selected account. Junk is flags then
move, two operations, in that order.

**Surfacing:** nothing under five attempts. At five, one aggregate indicator with a popover
listing the failures, **Retry now** and **Discard**. Never a modal, never one alert per
message. Publish the count; WS-13 renders it.

**Sign-out** with a non-empty queue asks: Send now, Discard, Cancel.

## Acceptance

Every test in [../../architecture/offline-queue.md](../../architecture/offline-queue.md#testing-it),
plus live:

- Airplane mode: archive ten messages, star three, delete two. All stick. Quit. Relaunch.
  All still there, still queued.
- Reconnect: the queue drains in order, the count ticks down, and the web client shows
  every change.
- Star-unstar-star offline produces **one** request and the right final state.
- A message deleted in the web client while an action for it is queued: the operation is
  dropped quietly and the local row reconciled. No error.
- Five consecutive 500s produce exactly one visible indicator, and `Retry now` works.
- Discard reverts the local change to exactly the pre-action state.

## Out of scope

The buttons and shortcuts (WS-10 — you provide `perform`, they call it). Sync (WS-05, whose
ordering rule you depend on). Compose or send.

## Report

Additionally: whether the collapsing rules held on real usage or produced a surprise, and
what the drain does on a queue of a thousand operations after a long offline stretch —
including how long it takes.
