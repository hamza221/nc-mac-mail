# ADR-0011: FTS5 table holding its own copy of the text

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture

## Context

Local search is the capability the mirror unlocks, so it has to be good: instant,
typo-tolerant on prefixes, across every mirrored mailbox and account. SQLite's FTS5 does
this well, and offers three storage arrangements:

1. **External content** (`content='message'`) — the index references another table's rows
   and stores no text. Cheapest on disk, but it can only index columns of that one table,
   and our searchable text lives across `message`, `messageBody` and `messageAddress`.
2. **Contentless** (`content=''`) — stores no text and cannot return it. Deleting and
   updating rows requires `contentless_delete=1`, which needs SQLite 3.43+; the version
   available is the one macOS ships, which we would rather not have to reason about per OS
   update.
3. **Standalone** — an ordinary FTS5 table that stores its own copy of the indexed text.

## Decision

A standalone FTS5 table, `messageSearch`, with `rowid = message.id` and four columns —
`subject`, `preview`, `body`, `people` — maintained in the same transaction as the writes
that feed it.

```sql
CREATE VIRTUAL TABLE messageSearch USING fts5(
    subject, preview, body, people,
    tokenize = 'unicode61 remove_diacritics 2'
);
```

## Consequences

- Insert, update and delete are ordinary statements on every SQLite version we will meet.
- One row can index text from three tables, which is what the data actually looks like.
- `people` is a flattened `"Name <addr>"` join of from, to and cc, so "everything involving
  Sookie" is one query rather than a join.
- `remove_diacritics 2` means *Zoë* matches *Zoe*, which matters in a European product.
- Costs a second copy of the message text — roughly 20% of body size in practice. The
  mirror already committed to storing that text; this is a fraction on top, and
  [ADR-0008](0008-no-automatic-eviction.md) already gives the user a way to reclaim it.
- Consistency is a transaction discipline: any write to `message` or `messageBody` updates
  `messageSearch` in the same transaction. One helper does it; a store test asserts that
  no row can exist in one and not the other.
- `bm25()` gives ranking for free, weighted toward subject and people over body.

## Alternatives considered

**External content.** The right answer if all searchable text lived in one table. It does
not, and denormalising the body into `message` to make it fit would be worse than a second
copy.

**Contentless with `contentless_delete`.** Saves the copy; needs a SQLite version guarantee
we do not control, and fails in a way that only shows up on an older OS.

**`LIKE '%term%'` over the body.** No index, full scan, no ranking, no tokenisation. Fine
for a thousand messages, useless at fifty thousand.

## Revisit when

Disk measurements come in from a real corpus (WS-11), or the minimum supported macOS
guarantees a SQLite new enough for contentless deletes to be uninteresting.
