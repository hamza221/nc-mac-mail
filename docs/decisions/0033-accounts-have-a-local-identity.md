<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0033: Rows the server numbers get a local id and keep the server's as `remoteId`

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** the wave-2 identity fix, from a collision WS-04 hinted at and WS-13 made reachable

## Context

`account.id` was the server's numeric Mail account id and the table's primary key. So were
`mailbox.id` (the server's `databaseId`), `message.id` and `tag.id`.

Those numbers are unique on one Nextcloud instance. They are counters in that instance's
own tables, and they say nothing at all across two. The app is built for two:

- WS-01 keys the Keychain item by host **and** login name, and `Keychain.allAccounts()`
  returns every pair.
- WS-13's `AppSession` builds an `AccountSession` per entry, each with its own server URL
  and its own `MailClient`.
- `LoginView` can be reached again after the first account, so a second instance is a
  supported gesture and not a hypothetical.

One mirror file, one `account` table, two servers that both number their first Mail account
`1`: the second sign-in's `upsert` updates the first one's row. No error, no warning, no
failing test. The same holds one level down, and this is the part the original framing
missed: `mailbox.databaseId` and `message.databaseId` are the same kind of counter. Two
instances will both have a mailbox 5 and a message 100, so fixing `account` alone would
have produced something that *looked* like multi-server support while messages from two
servers silently overwrote each other — worse than the bug, because it would be trusted.

This is not a corner. [S-10 "Several accounts"](../product/user-stories.md#s-10-several-accounts-ws-07)
is assigned to WS-07, which runs next, and `docs/product/overview.md` promises multiple
accounts in the same sentence as sign-in.

## Decision

Every table the server numbers gets a local primary key, and keeps the server's number in a
`remoteId` column that is unique only within its scope.

| Table | `id` | `remoteId` | Unique |
| --- | --- | --- | --- |
| `account` | local, `AUTOINCREMENT` | server's account id | `(serverURL, loginName, remoteId)` |
| `mailbox` | local, `AUTOINCREMENT` | server's `databaseId` | `(accountId, remoteId)` |
| `message` | local, `AUTOINCREMENT` | server's `databaseId` | `(accountId, remoteId)` |
| `tag` | local, `AUTOINCREMENT` | server's tag id | `(accountId, remoteId)`, `(accountId, imapLabel)` |

`account` also gains `serverURL` and `loginName`, which together are `ServerIdentity`. They
are deliberately the pair the Keychain item is keyed by, so the app can go from an account
row to the credentials that can talk to it without a second identity scheme.

Three consequences that are really the decision:

**A local id is the mirror's to assign, so no write carries one.** `AccountWrite`,
`MailboxWrite` and `EnvelopeWrite` have a `remoteId` and no `id`. GRDB's `upsert` with no
conflict target fires on *any* uniqueness violation, so the unique indexes above are what
find an existing row, and ADR-0023's "an absent column is a preserved column" is untouched.
`upsert(accounts:)` and `upsert(mailboxes:)` answer with the rows, because their local ids
are otherwise unknowable; `upsert(envelopes:)` answers with the ids.

**Requests take `remoteId`; rows take `id`.** `MirrorCoordinator` reads its account row
once per run and builds `GET /mailboxes?accountId=` from `remoteId`, primes and enumerates
from `mailbox.remoteId`, and fetches bodies from `message.remoteId` — while writing back
against the local ids. `nextBodyBackfillBatch` returns a `BodyBackfillItem` carrying both,
because that one call needs both. `MessageRow` carries `remoteId` too: WS-10 builds every
triage request from a selected row.

**The row comes before the coordinator.** A coordinator takes a local account id, which
only exists once the row does, so `MirrorCoordinator.discoverAccounts(store:client:identity:)`
is what runs first: `GET /accounts`, upserted under an identity, answering with the rows.
One coordinator per row. A coordinator built for an id with no row logs and stops rather
than inventing one.

`v1` is edited in place rather than followed by a `v2`. Nothing has shipped and no mirror
exists anywhere for a `v2` to migrate, so a migration would be ceremony describing a
transition that never happens. `docs/reference/schema.sql` moves with it in the same
commit, which is what `MigrationTests.schemaMatchesReference` checks.

`avatar` stays keyed by email address and is shared across accounts and servers. An avatar
is a picture of a person, the same person has the same address on both instances, and the
worst case is that one instance's picture is shown for the other's.

## Consequences

- Two servers, or two logins on one server, mirror into one file without touching each
  other's rows. `StoreWriteTests.twoServersWithTheSameNumericIdsDoNotCollide` writes
  account 1, mailbox 5 and message 100 twice from two identities and asserts six distinct
  rows; deleting one account leaves the other whole.
- Cross-account search (S-04) still reads one FTS table over one file, which is the reason
  this is one database with local ids rather than one database per server.
- Seeding 50,000 envelopes went from 14,954 ms to 17,002 ms, +13.7%, measured by
  `PerformanceTests.theWindowedListIsFastAtFiftyThousandRows` before and after. The cost is
  one cached `SELECT id FROM message WHERE accountId = ? AND remoteId = ?` per envelope,
  which the upsert needs before it can write addresses and the search row, plus
  `AUTOINCREMENT`'s `sqlite_sequence` update. The list queries themselves did not move:
  0.467 → 0.515 ms flat, 0.777 → 0.838 ms threaded, 0.079 → 0.110 ms backfill picker, all
  inside run-to-run noise on this machine. The backfill is bounded by the network by three
  orders of magnitude, so two extra seconds per fifty thousand envelopes is not a cost the
  user can see.
- `AUTOINCREMENT` rather than a plain rowid on all four tables, so an id is never reused
  after a delete. `pendingOperation.messageId` has no foreign key — it deliberately
  outlives the row it names — and a reused id would silently re-point a queued action at a
  different message.
- Every id in a log is now local. A support conversation that needs to be matched against a
  server's own logs has to go through `remoteId`, which is one more step than before.
- WS-07, WS-08, WS-10 and WS-12 read `remoteId` whenever they build a request and `id`
  whenever they touch a row. WS-05's incremental sync and WS-06's queue will do the same.
- `tag` now cascades with its account. `StoreWriteTests.deletingAnAccountLeavesNothingBehind`
  used to exempt it as "a per-server list of IMAP keywords", which was wrong twice: a
  keyword belongs to an account server-side, and "per server" stopped meaning anything the
  moment two servers could share the file.

## Alternatives considered

**Fix `account` only, as the problem was first framed.** Cheapest, and unsound: two
servers still collide on every mailbox and every message. It would have shipped something
that reads as multi-server support and loses mail.

**One mirror file per server.** No schema change at all, ids cannot collide because they
never share a database, and signing out is `rm`. Rejected because S-04 and
`docs/product/overview.md` both promise search across accounts, and one FTS5 index per file
means N queries whose bm25 scores are not comparable, merged by hand. It also scatters the
`meta` table — the launch theme, the restored selection, the pause flags — across files
with no obvious owner.

**Pack the server into the id, `localId = serverOrdinal << 48 | remoteId`.** Every index,
every foreign key and the FTS `rowid` trick survive untouched, and it is two lines of
arithmetic. Rejected: an id in a log or a crash report stops meaning anything, the ordinal
has to be allocated and never reused anyway, and the first reviewer would ask why not a
local id and a unique constraint. Which is this.

**Composite primary keys, `(accountId, remoteId)`.** Honest, and it breaks the FTS5 index,
which is keyed by an integer `rowid` that has to be `message.id`
([ADR-0011](0011-fts5-standalone-index.md)). It also makes every foreign key two columns
wide for no gain over a unique index.

**Keep the single-server key and document the limitation.** A legitimate v1 answer if the
product only ever talked to one instance. It does not: the Keychain enumerates pairs, the
app shell builds a session per pair, and nothing in the UI stops a second sign-in. The
limitation would have had to be a refusal to add a second server, which is a product change
and a bigger decision than this one.

## Revisit when

A mirror is big enough that the per-envelope id lookup in `upsert(envelopes:)` shows up in
a measurement — `upsertAndFetch` with `RETURNING id`, or one lookup per page rather than
per row, would both remove it. Or when a second table the server numbers is added and this
table has to grow a row.
