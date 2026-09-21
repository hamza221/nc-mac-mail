<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-11 — Local full-text search

**Wave 4, after WS-03 and WS-08. Size: M.**

## Goal

Type three letters, get results from forty thousand messages, instantly, offline. This is
the capability the mirror exists to unlock.

## Before you start

- [../../decisions/0011-fts5-standalone-index.md](../../decisions/0011-fts5-standalone-index.md)
- [../../reference/schema.sql](../../reference/schema.sql) — the `messageSearch` table
- [../../product/ux-spec.md](../../product/ux-spec.md) — search section
- [../../product/user-stories.md](../../product/user-stories.md) — S-04

## You own

`Packages/NCMailStore/Sources/NCMailStore/Search/**`, `NextcloudMail/Views/Search/**`

## Build

```swift
public struct SearchQuery: Sendable {
    public var text: String
    public var scope: Scope          // .mailbox(Int64) | .account(Int64) | .all
    public var flags: FlagFilter?    // unread, starred, has attachments
}

public func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> [SearchResult]
public func observeSearch(_ query: SearchQuery) -> AsyncValueObservation<[SearchResult]>
```

**Query translation.** User text becomes an FTS5 MATCH expression, and this is where the
bugs live:

- Every term gets a `*` suffix for prefix matching — people type as they think.
- Quoted phrases stay phrases.
- **Escape FTS5 syntax.** A user typing `NOT` or `"` or `-` must not produce a syntax error
  or, worse, a different query than they meant. Fuzz this.
- Empty or whitespace-only input returns nothing, not everything.
- Rank with `bm25()`, weighted toward `subject` and `people` over `body`.

**Coverage honesty.** While the backfill is incomplete, the footer says
"Searching 31,204 of 48,902 downloaded messages." Two queries, one counter, and it removes
the worst possible failure — a confident empty result over a partial index. It disappears
when the mirror completes.

Unsubscribed mailboxes are not indexed
([ADR-0007](../../decisions/0007-subscribed-mailboxes-only.md)). The scope control says so
when it would matter.

**UI.** `.searchable` on the list, ⌘F focuses, ⌘⇧F sets scope to all mail. Results replace
the list, matches highlighted with `NCHighlightText`, and result rows carry the mailbox name
because "all mail" spans folders. Escape clears and returns.

**Performance.** Results as you type means the query runs per keystroke — cancel the
in-flight one on the next character, and keep the whole round trip under a frame at 50,000
messages. Measure; do not assume.

## Acceptance

- 50,000-message corpus: results **under 50 ms**, measured, number in the report.
- Prefix matching works from the first character typed.
- `Zoë` matches `Zoe` and vice versa (the tokeniser strips diacritics).
- Searching for `NOT`, `"`, `-`, `*`, `(` and an emoji all behave sanely — no crashes, no
  syntax errors, no surprising result sets.
- Scope switching is instant, and `.all` spans accounts.
- Works fully offline.
- Coverage footer is accurate mid-backfill and gone when complete.
- A message deleted locally disappears from results immediately.

## Out of scope

Server-side search and the filter-string syntax — v1 does not use them. Saved searches,
smart mailboxes, search history: all post-v1.

## Report

Additionally: the measured latency; the FTS index size against real data; and whether
`bm25()` weighting produced sensible ordering on real mail or needed tuning — with an
example that convinced you either way.
