<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0030: Stage 1 owns its cursor — envelopes commit first, and priming never moves it

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-04, against what `local-mirror.md` asked for, after finding the store's
API cannot express it and that it does not need to

## Context

[local-mirror.md](../architecture/local-mirror.md) gave stage 1 two instructions that WS-04
could not follow literally.

**One transaction.** "Write the page and the new `mailbox.envelopeCursor` in one
transaction. A crash between the two is the only way to get a gap, and there is no
between." The store's write path for a page is `MailStore.upsert(envelopes:)`, which writes
the `message` rows, rewrites `messageAddress`, and calls `SearchIndexWriter.indexEnvelope`
inside a transaction it opens itself. `SearchIndexWriter` and `EnvelopeWrite.indexedPeople`
are internal to `NCMailStore`, so a caller that wanted the cursor in the *same* transaction
would have to reimplement the page write from outside the module and keep it in step with
ADR-0024's trigger by hand. WS-03's own note to WS-04 says as much: use `store.write { }`
directly if you need them together.

**Skipping the first page.** "The response also carries the first full envelope set for the
mailbox (`findAllIds` when `ids` is empty), so stage 1 can skip its first page." Verified
against the live server: `POST /mailboxes/5/sync {"ids": [], "init": true}` returns 200 with
95 `newMessages` for a mailbox `GET /messages?view=singleton` also reports as 95. The claim
holds on this server, at this size.

## Decision

**Two transactions, in the order envelopes-then-cursor.** `upsert(envelopes:)` commits the
page; `setEnvelopeCursor(_:complete:mailboxId:lastSyncAt:)` commits the cursor immediately
afterwards.

**Priming stores its envelopes and leaves the cursor alone.** Stage 1 always starts from the
cursor in the database, which on a fresh mailbox means re-reading page one.

## Consequences

The ordering is the guarantee, and it is the only part that matters. A crash between the two
commits leaves a cursor pointing at a page that is already stored, so the next run re-fetches
that page and upserts it by primary key on top of itself. The cost of a `kill -9` is one
cheap request. The reverse order is the one that loses mail: a cursor past messages that were
never written is a hole nothing downstream would ever look for, because as far as the cursor
is concerned the mailbox is done. "At most one page re-fetched" is what the brief's
acceptance list actually asks for, and it is what this gives.

Not skipping page one costs one request per mailbox, once — five requests on the live
account, and a database read on the server rather than an IMAP fetch. What it buys is that
"all" never has to mean all. `findAllIds` returning the whole mailbox was measured on a
95-message folder; nothing in the source promises the same on 50,000, and a client that
skipped page one on the strength of that measurement would lose the difference silently. The
cursor is derived from pages the mirror itself paged through, and from nothing else.

Two transactions also means a page and its cursor can be observed apart by a
`ValueObservation`, so the message list can flicker one page ahead of the sidebar's progress
count for a few milliseconds. Nobody can see it, and the alternative is worse.

## Alternatives considered

**Reimplement the page write inside `store.write { }`.** Duplicates `upsert(envelopes:)`
including the address rewrite and the FTS row, from outside the module that owns them, where
a schema change would break it silently rather than at compile time.

**Ask WS-03 for `upsert(envelopes:cursor:complete:mailboxId:)`.** The honest fix if the
single transaction were needed. It is not — the ordering already removes the failure mode the
single transaction was there to remove — so it would be a new public method to make a comment
in a document true. Raised in WS-04's report as an option rather than taken unilaterally.

**Write the cursor first.** The one order that can lose messages. Named here so nobody
re-derives it as an optimisation.

**Skip page one after a successful prime.** Saves one request per mailbox per lifetime and
makes completeness depend on an undocumented property of a PHP query at a size nobody has
tested.

## Revisit when

`MailStore` gains a page-plus-cursor write, or the deep reconcile in
[sync-engine.md](../architecture/sync-engine.md) is shown to be too infrequent to catch the
hole a mis-ordered write would leave — in which case the ordering, not the transaction count,
is what to look at first.
