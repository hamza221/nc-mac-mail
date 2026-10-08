<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0105: Removed mail leaves the file — the search indexes are rebuilt before every removal's `VACUUM`

**Status:** Accepted
**Date:** 2026-10-08
**Decided by:** the security audit's findings `ncmailstore/search-index/fts5-deleted-postings-retained`
and `ncmailstore/avatars/rows-outlive-account-deletion`, reproduced in the store's own tests by
searching the bytes of a vacuumed, checkpointed `mirror.sqlite`, and a write-cost measurement
that ruled out the audit's first remedy

## Context

Signing out with **Remove Local Copies**, **Settings › Storage › Remove local copies** and
**Re-download** promise that the account's mail is gone from this Mac
([local-mirror.md](../architecture/local-mirror.md)). Signing out removes the whole login
(`MailStore.deleteLogin`, [ADR-0079](0079-a-login-table-roots-instance-state.md)), contacts
included. Every query agreed. The file did not:

- `messageSearch` is a default FTS5 table. A deleted or emptied row appends a delete marker
  that hides its postings from queries; the postings stay in `messageSearch_data` until a
  merge happens to combine the two. `VACUUM` copies live pages, and those are live pages. A
  removed message's subject and body words stayed readable in the file, some only as the
  suffix FTS5 stores when a term shares a prefix with the one before it. `contactSearch`
  does the same with a removed login's contact names and addresses.
- `avatar` is keyed by address and shared across accounts
  ([ADR-0033](0033-accounts-have-a-local-identity.md)), with no `accountId` and no foreign key,
  so no cascade reached it. A removed account's correspondents, their photos and fetch times
  survived.

v1 has shipped, so mirrors holding remnants of earlier removals exist.

The audit proposed FTS5's `secure-delete` option, which makes every delete and update remove
its postings at once. Measured with the system SQLite (3.51.0) on 5,000 messages shaped like
the mirror's rows (six-word subject, twenty-word preview, three-word people, 300-word body),
one transaction each as the backfill writes them:

| Write | default | `secure-delete` |
| --- | --- | --- |
| Body written over an envelope-only row | 0.29 ms | 1.2 ms |
| Envelope re-indexed on a row that has a body (2,500 rows) | 0.34 ms | 9.5 ms |
| 2,500 bodied rows deleted in one transaction | 0.38 s | 11.1 s |
| `rebuild` of all 5,000 rows | 0.62 s | — |

`SearchIndexWriter.indexEnvelope` re-indexes every envelope every sync page writes, and the
mirror has one `DatabaseQueue` that every read waits behind. At 50,000 messages, the last row
is a sign-out holding the queue for minutes.

## Decision

- **`MailStore.vacuum()`**, which every removal path calls straight after its delete, runs
  FTS5 `rebuild` on `messageSearch` and `contactSearch`, then `VACUUM`, then
  `PRAGMA wal_checkpoint(TRUNCATE)`. A rebuild rewrites an index from the table's own
  content, which no longer holds the removed text; `VACUUM` drops the pages the old segments
  occupied; the checkpoint empties the write-ahead log, which otherwise holds the vacuumed
  pages and older frames until SQLite checkpoints on its own. `optimize` was tried in place
  of `rebuild` and left removed words in the merged segment.
- **Migration `purgeRemovedSearchPostings`** runs the same two rebuilds once, after `v4`,
  for mirrors whose removals were vacuumed without them. It runs with SQLite's page-level
  `secure_delete` on for those statements, so the pages the old segments occupied are zeroed
  as they are freed instead of waiting on the free list for the next `VACUUM`; the
  connection's setting is put back afterwards.
- **`MailStore.deleteAccount(id:)` and `MailStore.deleteLogin(_:)`** delete, in the same
  transaction, the `avatar` rows that neither a remaining message's sender nor a remaining
  contact's address names (`NOT IN` over `lower(fromEmail)` with `NULL`s filtered, and over
  `lower(contactEmail.email)`; [ADR-0104](0104-one-fold-for-the-avatar-key.md) for the
  fold). Rows other mail or another login's contacts still name stay.
  `upsert(avatar:accountId:)` writes nothing for an account that no longer exists, because
  the account's fetcher stops after the row goes and an answer in flight would otherwise
  bring an address back.

## Consequences

- Removal is complete on disk, and the store's tests say so by searching the raw file and its
  log for a removed word and its suffix after each removal path, after a login's contacts
  are removed, and after opening a v1 file that a removal had left remnants in.
- Ordinary writes cost what they cost before.
- `vacuum()` re-tokenises the whole index, every account's: about 1.2 s per ten thousand
  messages, on top of a `VACUUM` that already rewrote the whole file, behind a progress
  indicator.
- Between a removal's delete and its `vacuum()` the postings are still in the file, as the
  rows themselves are in freed pages. A removal interrupted there is completed by the next one.
- Mail deleted any other way (an expunge, a message moved out of a mirrored mailbox) leaves
  postings until a merge or the next removal, exactly as its rows leave freed pages. Only the
  removal controls promise the text is gone.
- The purge migration's `rebuild`s cost one re-tokenisation on the first launch after the
  update. It is named for what it does rather than `v5`: it changes no schema object, so the
  schema stays `v4` and `schema.sql` describes it unchanged.
- Avatar rows for addresses no message names any more are removed only when an account is. A
  sender whose mail was all expunged keeps a row until then; it is a picture the user saw, not
  something a removal promised to take.

## Alternatives considered

**FTS5 `secure-delete`.** Physical at every delete, not only at removal, and what the audit
proposed. Rejected on the measurements above: it makes the writes the mirror does most and
the removal itself an order of magnitude slower on the queue every read shares.

**`optimize` instead of `rebuild`.** Cheaper (0.32 s against 0.62 s on the same 5,000 rows),
and measured insufficient: removed words survived in the merged segment.

**Page-level `PRAGMA secure_delete` on every connection.** Zeroes freed pages for good, which
is I/O on every write the mirror makes. `VACUUM` already drops freed pages at the only moments
the user asked for something to be gone.

**A one-time `VACUUM` after the migration.** Would also clear free pages left by removals
interrupted before their `VACUUM`. Not done: it blocks opening the store for as long as the
file takes to rewrite, and a removal that completed had already vacuumed.

## Revisit when

A removal path appears that does not end in `vacuum()`, the app starts promising that mail
deleted in other ways is gone from the disk, or the mirror moves to an encrypted database
([ADR-0006](0006-data-at-rest.md)).
