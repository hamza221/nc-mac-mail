<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0024: Delete the search index row from a trigger, not from Swift

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-03, while writing the "delete an account and count every table" test

## Context

[ADR-0011](0011-fts5-standalone-index.md) chose a standalone FTS5 table and said how it stays
correct: "any write to `message` or `messageBody` updates `messageSearch` in the same
transaction. One helper does it."

That works for inserts and updates, because every one of them starts as a call into the
store. It does not work for deletes, because not every delete does. The schema cascades:

```sql
mailboxId INTEGER NOT NULL REFERENCES mailbox(id) ON DELETE CASCADE,
accountId INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
```

`DELETE FROM account WHERE id = ?` removes an account's messages without any Swift code
mentioning a message. A standalone FTS5 table is a virtual table and cannot be the child of a
foreign key, so nothing removes its rows. Sign out of an account and its subjects and senders
stay searchable, in a table the mirror will never revisit. The brief's own acceptance
criterion — "deleting an account leaves no orphans in any table" — fails, and only because a
table was left out of the counting.

The same hole is open to every workstream that deletes: WS-05's reconcile, WS-06's drainer on
a 404, WS-12's sign-out. A rule that four other agents have to remember is not a rule.

## Decision

Inserts and updates stay in `SearchIndexWriter`, exactly as ADR-0011 says. Deletes move into
the schema:

```sql
CREATE TRIGGER messageSearchDelete AFTER DELETE ON message BEGIN
    DELETE FROM messageSearch WHERE rowid = old.id;
END;
```

`docs/reference/schema.sql` and the v1 migration both carry it, and the migration test diffs
them.

## Consequences

- Any delete of a `message` row takes its index row, whoever issued it and however indirectly.
  `SearchIndexTests.cascadingFromAMailboxRemovesIndexRows` and
  `StoreWriteTests.deletingAnAccountLeavesNothingBehind` assert it from both ends.
- `MailStore.deleteMessages(ids:)` is one statement instead of two, and no caller has to pair
  a delete with an index delete.
- The maintenance is now in two places — a trigger for deletes, Swift for the rest — which is
  a thing to know before reading either. Both say so in a comment, pointing here.
- A trigger runs per deleted row. Removing an account of 250,000 messages fires it 250,000
  times. It is one `DELETE … WHERE rowid = ?` against an FTS5 table each time, inside the
  transaction that was already deleting 250,000 rows, and sign-out is not a hot path.

## Alternatives considered

**Delete index rows explicitly before every cascade.** `DELETE FROM messageSearch WHERE rowid
IN (SELECT id FROM message WHERE accountId = ?)`, then the cascade. Correct in the two places
WS-03 owns, and silently wrong the first time another workstream writes a `DELETE FROM
message` of its own. The whole point of a mirror nobody notices is that it cannot be got
subtly wrong from four directions.

**Triggers for insert and update too.** The standard FTS5 pattern, and it would put the whole
invariant in the schema. Rejected because the indexed text is assembled from three tables:
`message` gives subject and preview, `messageBody` gives the body, `messageAddress` gives
people. An insert trigger on `message` cannot see a body that has not been fetched yet, so it
would write a blank one and the body write would have to update it anyway — the same two-step
as now, split across SQL and Swift instead of sitting in one readable helper.

**Contentless FTS5 with `contentless_delete=1`.** Already rejected by ADR-0011, for a SQLite
version guarantee we do not control. Nothing here changes that.

## Revisit when

The `people` and `body` columns stop coming from other tables — if, say, a future schema
denormalised both onto `message` — at which point the whole index could be maintained by
triggers and `SearchIndexWriter` could go away.
