<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0023: Store records are their own types, and a write is narrower than a row

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-03, from a bug the first draft of the upsert had

## Context

The WS-03 brief names four writes:

```swift
public func upsert(accounts: [Account]) async throws
public func upsert(mailboxes: [Mailbox], accountId: Int64) async throws
public func upsert(envelopes: [Envelope]) async throws
public func upsert(body: MessageBody, for messageId: Int64) async throws
```

`Account`, `Mailbox`, `Envelope` and `MessageBody` are the names WS-02 gave its decoded wire
models in `NCMailCore`. Reading the signatures literally means the store persists the wire
models directly.

Two things make that wrong, and the second is the one with teeth.

**A row is not a payload.** `mailbox` has thirteen columns the server never sends:
`isMirrored`, `envelopeCursor`, `envelopesComplete`, `bodiesComplete`, `lastPrimedAt`,
`syncFailureCount`, `lastSyncError` and the rest. `message` has `bodyState` and `syncedAt`.
`account` has `mirrorState` and `lastDeepReconcileAt`. That is the mirror's own progress, and
it is the reason "quit mid-backfill and relaunch" is a non-event.

**An upsert of a whole row destroys that progress.** GRDB's `upsert` writes
`INSERT … ON CONFLICT DO UPDATE SET` over every column the record encodes. Persist a whole
`MessageRecord` built from a re-synced envelope and `bodyState` goes back to whatever the
caller happened to have in hand — in practice `missing`, because the sync engine does not
know about bodies. The mirror then re-downloads a body it already has, every time a flag
changes, forever. Nothing fails; it just never settles.

## Decision

`NCMailStore` defines its own types and never imports WS-02's models.

**Two types per table where the server owns only part of the row.** `AccountRecord` and
`AccountWrite`, `MailboxRecord` and `MailboxWrite`, `MessageRecord` and `EnvelopeWrite`. The
record is the whole row and is what reads return. The write carries only the columns the
server owns, and the columns it does not mention are neither inserted nor updated, so an
absent column is a preserved column rather than a defaulted one.

The DAO signatures become `upsert(accounts: [AccountWrite])`, `upsert(mailboxes:
[MailboxWrite], accountId:)`, `upsert(envelopes: [EnvelopeWrite])` and `upsert(body:
MessageBodyWrite, for:)`. `messageBody` has no server-versus-mirror split — the whole row is
written by one fetch — so `MessageBodyWrite` exists only to keep `byteSize` out of the
caller's hands.

Mapping a decoded `Envelope` to an `EnvelopeWrite` is `NCMailSync`'s job, which is where the
two halves are already allowed to meet.

**The sidebar observation returns rows, not a tree.** The brief asks for
`observeMailboxTree(accountId:) -> AsyncValueObservation<[MailboxNode]>`. `MailboxNode` is
WS-07's, it lives in `NCMailCore`, and it wraps WS-07's `Mailbox` — so the store cannot build
one without importing exactly what this decision is about. It also should not want to:
`MailboxTree.build(from:delimiter:)` is described in the WS-07 brief as "a pure function in
`NCMailCore`, and the most testable thing in the app", and it stops being that the moment a
database is between it and its test. The store publishes
`observeMailboxes(accountId:) -> AsyncValueObservation<[MailboxRecord]>` and WS-07 builds the
tree from the rows.

## Consequences

- The clobbering bug is not a discipline to remember. `EnvelopeWrite` has no `bodyState`
  property, so no caller can write one. `StoreWriteTests.reSyncingAnEnvelopeKeepsTheBodyState`
  and `refreshingAMailboxKeepsItsMirrorProgress` hold the line.
- `NCMailStore` compiles without `NCMailCore`'s models in scope, which keeps the module rule
  in [overview.md](../architecture/overview.md) true by construction rather than by habit.
- WS-04 writes a mapping function per entity. Four small ones, all pure, all testable without
  a database or a server.
- Names do not collide when a module imports both. The store's flag bundle is `EnvelopeFlags`
  rather than `MessageFlags`, which [ADR-0021](0021-one-message-flags-type.md) gave to
  `NCMailCore`.
- Two struct definitions per table is real duplication. It is worth it for `message` and
  `mailbox`, which is why `messageBody`, `attachment`, `avatar`, `tag`, `meta` and
  `pendingOperation` have one type each: the server owns all of those rows or none of them.

## Alternatives considered

**Persist the wire models directly.** What the brief's signatures say. Rejected for the
reason above, and because it would make `NCMailStore` depend on `NCMailCore`'s decoding — a
server that renames a field would then break the schema rather than one mapping function.

**One record per table, with `upsert(updating: .noColumnUnlessSpecified)`.** GRDB supports it.
It moves the column list from a type declaration into a closure of twenty-five
`ColumnAssignment`s at every call site, and a column forgotten there fails silently in exactly
the way this decision exists to prevent.

**One record per table, with the caller reading the row first and merging.** A read before
every write, and a race between the two unless the whole thing is one transaction. More code
and more cost for a weaker guarantee.

## Revisit when

A table grows a third category of ownership — say, columns the user edits locally and the
server never sees — and two types stop being enough to describe who writes what.
