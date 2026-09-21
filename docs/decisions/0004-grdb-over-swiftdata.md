# ADR-0004: GRDB.swift over SwiftData

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Product owner, from a three-way comparison

## Context

[ADR-0003](0003-local-first-full-mirror.md) needs a database that can hold hundreds of
thousands of rows, answer a windowed list query in single-digit milliseconds, do full-text
search, push changes to SwiftUI, and migrate across versions without losing a user's
mirror.

Three candidates: SwiftData, GRDB.swift, raw SQLite behind our own wrapper.

## Decision

**GRDB.swift**, as the only third-party dependency in the app besides `NextcloudUI`.

## Consequences

- **FTS5** is built in, which is [ADR-0011](0011-fts5-standalone-index.md) and most of the
  search workstream.
- **`ValueObservation`** gives SwiftUI a live query with the semantics we want, including
  the windowing a 50,000-row list needs.
- **`DatabaseMigrator`** is an explicit, ordered, testable migration list. We can assert
  that the migrated schema equals [../reference/schema.sql](../reference/schema.sql), which
  turns a class of upgrade bug into a failing test.
- **Value-type records** match the `Sendable` model types the rest of the app already
  uses; nothing needs to be a reference type to be stored.
- Write transactions are explicit, so "apply locally and queue the operation, atomically"
  ([ADR-0005](0005-offline-mutation-queue.md)) is a language-level guarantee rather than a
  convention.
- One dependency to vendor, audit and update. MIT, compatible with AGPL distribution,
  actively maintained, and widely used in shipping Apple software.
- Contributors need to know SQL. For this application that is a feature: the queries in
  [../reference/schema.sql](../reference/schema.sql) are the performance-critical part of
  the app and they deserve to be visible.

## Alternatives considered

**SwiftData.** First-party, no dependency, good Xcode story. Loses on four counts: `@Model`
wants reference types where our model layer is deliberately value types; no FTS5, so
search becomes `LIKE` over a large table; migrations are less explicit and harder to test;
and its observation and concurrency behaviour under heavy background writes — which is
precisely our backfill — is not something to be learning on this project. A mirror is a
database problem, and SwiftData is an object-graph tool.

**Raw SQLite behind our own wrapper.** No dependency, full control, FTS5 available. Costs a
migration runner, statement caching, an observation mechanism and a concurrency story —
about a week of work to reimplement badly what GRDB does well, plus permanent ownership.

## Revisit when

SwiftData gains FTS and a value-type story, or GRDB stops being maintained.
