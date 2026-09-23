<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0043: The mutation queue talks to a protocol, because `NCMailStore` has no queue DAO

**Status:** Superseded by [ADR-0045](0045-the-store-grows-the-queue-dao-and-the-readers.md)
**Date:** 2026-09-23
**Decided by:** WS-06, against the same boundary [ADR-0037](0037-the-queue-is-read-twice-around-the-sync-write.md) hit

## Context

[offline-queue.md](../architecture/offline-queue.md) and
[ADR-0005](0005-offline-mutation-queue.md) both rest on one statement:

```swift
try await store.write { db in
    try applyLocally(db)
    try PendingOperation(...).insert(db)
}
```

That code cannot be written from `NCMailSync`. [ADR-0034](0034-the-store-returns-its-own-sequence.md)
made `MailStore.read` and `MailStore.write` internal so that no GRDB type crosses the store's
boundary, and it named the standing cost itself: "the next thing that wants a query the store
does not have needs a DAO rather than a closure". `NCMailStore` has the `pendingOperation`
table and `PendingOperationRecord`, and no queries over either. WS-03's note to WS-06 said the
shape above "works as written"; it was written before ADR-0034 and it does not.

WS-06 owns `NCMailSync/Sources/NCMailSync/Operations/**` and nothing else, and `CLAUDE.md` is
explicit: "Need a change elsewhere? Write it in your report. Do not reach across." ADR-0037
faced the identical choice for a twenty-line DAO and did not reach across either.

## Decision

`Operations/**` declares `OperationStoring`: the eight methods the queue needs from the
mirror, in the mirror's own vocabulary (`PendingOperationRecord`, `MessageRecord`,
`MailboxRecord`), plus one value type, `LocalEffect`, describing what an operation does to a
message row.

`MutationQueue` and `OperationDrainer` are built against that protocol. The conformance for
`MailStore` lives in `NCMailSyncTests/OperationStoreSupport.swift`, where `@testable import
NCMailStore` reaches the internal `read`/`write` — so every test in this workstream runs
against the real schema, the real transactions and real GRDB, and none of them runs against a
fake store.

**The replacement is named.** WS-03 adds
`Packages/NCMailStore/Sources/NCMailStore/Queries/MailStore+Operations.swift` with the four
methods that are genuinely new — `enqueue(_:applying:)`, `pendingOperations(accountId:)`,
`markInFlight(ids:)`/`reschedule(ids:attempts:nextAttemptAt:lastError:)`,
`finish(ids:applying:)` — plus `threadMessages(accountId:rootId:)`. `LocalEffect` and
`MessageFlagColumns` move down beside them, because a store method cannot take a type from a
module above it. `OperationStoring` then disappears: `MailStore` simply has the methods, and
the four forwardings in the test file go with it. The bodies move unchanged; they are already
written and already tested.

## Consequences

- **The queue cannot be wired into the app until that file exists.** Nothing outside
  `NCMailSync` can construct a `MutationQueue`, because nothing outside can produce an
  `OperationStoring`. Every behaviour in this workstream is implemented and tested; none of it
  is reachable from `NextcloudMail/**`. WS-10 and WS-12 are blocked on the same file.
- Every test runs against the real database rather than an in-memory stand-in, which is a
  better outcome than the shortcut would have produced.
- One extra indirection while the protocol lives, and one more place the eight signatures are
  written down.
- The port is not a general abstraction and is not meant to grow. It has exactly the methods
  the queue calls, and it is deleted rather than extended.

## Alternatives considered

**Add the DAO to `NCMailStore` anyway.** It is one file and it is someone else's package.
ADR-0037 refused the same shortcut for the same reason two days earlier, and a rule that bends
the second time it is inconvenient is not a rule.

**Compose the local change out of the public API that exists.** `upsert(envelopes:)` is the
only public write over `message`, it takes a whole `EnvelopeWrite`, and it rewrites
`messageAddress` from `envelope.addresses` — so rebuilding one from a `MessageRecord`, which
carries no addresses, would silently delete every recipient of the message. There is also no
public insert for `pendingOperation` at all, and two public calls are two transactions, which
is precisely the atomicity ADR-0005 exists to guarantee.

**Open a second `DatabaseQueue` on the same file from `NCMailSync`.** Two writers on one
SQLite file, against `MailStore`'s own documented "there is exactly one writer", to work
around a missing method. No.

**Ship the queue with an in-memory store and leave the real one to WS-03.** Same amount of
production code, and the tests would prove the queue against a fake rather than against the
schema — which is the half most likely to be wrong.

## Revisit when

`MailStore+Operations.swift` lands. This record is then superseded and the protocol is
deleted in the same change.
