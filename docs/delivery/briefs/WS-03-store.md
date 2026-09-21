<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-03 — GRDB stack, schema, migrations, DAOs

**Wave 1, after WS-00. Size: L. Parallel with WS-01 and WS-02.**

## Goal

The database the whole app reads from: schema, migrations, records, queries, and live
observation — fast enough that a 50,000-row mailbox renders in a frame.

## Before you start

- [../../reference/schema.sql](../../reference/schema.sql) — **the contract you implement**
- [../../decisions/0004-grdb-over-swiftdata.md](../../decisions/0004-grdb-over-swiftdata.md)
- [../../decisions/0011-fts5-standalone-index.md](../../decisions/0011-fts5-standalone-index.md)
- [../../architecture/local-mirror.md](../../architecture/local-mirror.md)
- [../../architecture/concurrency.md](../../architecture/concurrency.md) — observation section

## You own

`Packages/NCMailStore/Sources/NCMailStore/**` except `Search/**` (WS-11)

## Build

**The stack.**

```swift
public final class MailStore: Sendable {
    public init(url: URL) throws            // WAL, foreign keys on, migrations applied
    public static func inMemory() throws -> MailStore
    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T
    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T
}
```

WAL mode, `PRAGMA foreign_keys = ON`, a `DatabaseQueue` (not a pool — one writer, and WAL
already lets readers through). Database at
`~/Library/Containers/…/Application Support/NextcloudMail/mirror.sqlite`.

**Migrations.** `DatabaseMigrator`, one registered migration per version, starting with
`v1` that produces exactly [../../reference/schema.sql](../../reference/schema.sql).

The test that makes this a contract rather than a hope:

```swift
@Test func schemaMatchesReference() throws {
    let migrated = try normalisedSchemaDump(of: MailStore.inMemory())
    let reference = try normalisedSchemaDump(ofSQLFile: "schema.sql")
    #expect(migrated == reference)
}
```

Normalise whitespace and comments, not names or types. If they diverge, one of the two is
wrong and the build should say so.

**Records** — value types conforming to `FetchableRecord, PersistableRecord, Sendable`,
one per table, camelCase columns so no `CodingKeys` are needed.

**DAOs** — the queries, each one used by a named caller:

```swift
public func upsert(accounts: [Account]) async throws
public func upsert(mailboxes: [Mailbox], accountId: Int64) async throws
public func upsert(envelopes: [Envelope]) async throws        // + addresses + FTS, one transaction
public func upsert(body: MessageBody, for messageId: Int64) async throws
public func deleteMessages(ids: [Int64]) async throws

public func observeMailboxTree(accountId: Int64) -> AsyncValueObservation<[MailboxNode]>
public func observeMessages(mailboxId: Int64, view: ListView, range: Range<Int>) -> AsyncValueObservation<[MessageRow]>
public func observeThread(rootId: String, mailboxId: Int64) -> AsyncValueObservation<[MessageRow]>
public func body(messageId: Int64) async throws -> StoredBody?

public func nextBodyBackfillBatch(accountId: Int64, limit: Int) async throws -> [Int64]
public func mirrorProgress(accountId: Int64) async throws -> MirrorProgress
public func storageFootprint(accountId: Int64) async throws -> StorageFootprint
```

Three rules with teeth:

1. **`MessageRow` is a projection**, not a record. A list row needs eight fields; the table
   has thirty. Fetching thirty for a list is how a list gets slow.
2. **`observeMessages` is windowed.** It takes a range and the caller extends it. Never
   materialise 50,000 rows.
3. **FTS is maintained in the same transaction** as any write to `message` or
   `messageBody`. One helper does it, and a test asserts no row can exist in one without
   the other.

**Threaded query.** The threaded view is the newest message per `threadRootId` plus counts.
It must use `idxMessageThread`; assert the query plan in a test, because an index that
silently stops being used is how a fast list becomes a slow one between two releases.

## Acceptance

- Migration from empty produces the reference schema; the test proves it.
- 50,000 synthetic messages seeded; the windowed list query returns its first 50 rows in
  **under 10 ms**, measured, with the number in the report.
- The threaded query uses the index. Assert `EXPLAIN QUERY PLAN`.
- Deleting an account leaves no orphans in any table — assert by counting every table.
- `ValueObservation` fires on a background write and delivers on the main actor.
- FTS insert/update/delete stay consistent under concurrent writes.
- All tests use an in-memory database and none touch the network.

## Out of scope

Search queries and ranking (WS-11 — you provide the table and the maintenance, they provide
the query). Any HTTP. Any sync logic. Views.

## Report

Additionally: the measured query times; the disk size of a 50,000-message synthetic
database with bodies, which replaces the estimate in
[../../architecture/local-mirror.md](../../architecture/local-mirror.md#sizing-so-nobody-is-surprised);
and any schema change you needed, applied to `schema.sql` in this pull request.
