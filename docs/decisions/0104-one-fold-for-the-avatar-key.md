<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0104: The avatar key is SQLite's `lower()` of the address, computed by SQLite

**Status:** Accepted
**Date:** 2026-10-08
**Decided by:** the security audit's finding `ncmailstore/avatars/sqlite-lower-vs-swift-lowercased-key`,
reproduced with `Ö@example.invalid` and U+212A (KELVIN SIGN) `evin@example.invalid` against
the real `AvatarFetcher` and a fake transport

## Context

`avatar` is keyed by address ([ADR-0061](0061-avatars-are-fetched-into-the-mirror-by-sync.md)),
case-insensitively, because a header may spell the same mailbox any way. The key went through two
different folds:

- `MailStore.upsert(avatar:)` stored Swift's `email.lowercased()`, which folds all of Unicode.
- `sendersNeedingAvatars` selected, grouped and excluded by SQLite's `lower(m.fromEmail)`, and
  the readers matched `COLLATE NOCASE`. GRDB links the system SQLite, which is built without
  ICU, so both fold ASCII only.

For an ASCII address the two agree. For `Ö@example.invalid` the writer stored `ö@…`, the work
list kept asking for `Ö@…`, and `AvatarFetcher.runPass`, which ends only when the work list is
empty, asked the server about the same address in a loop with no sleep, on every launch and
every reconnect. A photo stored under `ö@…` was never found by the reader. Swift also folds
U+212A to an ASCII `k`, so a sender spelling `Kevin` with the Kelvin sign overwrote the real
`kevin@` correspondent's photo with whatever the server said about the look-alike.

## Decision

- One fold, SQLite's `lower()`, applied by SQLite everywhere `avatar.email` is written or
  compared. The writer is a single `INSERT … SELECT lower(:email) … ON CONFLICT` statement; the
  readers match `email = lower(?)`; the work list and the cleanup already used `lower()`.
- `upsert(avatar:accountId:)` takes the account the fetch was for and writes nothing once that
  account is gone (see [ADR-0105](0105-removed-mail-leaves-the-search-index.md) for why that
  matters to removal). Contact photos (`ContactAvatars`) go through `upsert(avatar:)`, the
  same statement without the account check, so the two writers cannot fold differently.
- `AvatarFetcher.runPass` asks about each address at most once per pass, and a batch with
  nothing new ends the pass. That makes termination independent of the fold being right: if
  a key ever fails to retire its own work-list entry again, the pass stops instead of looping.

## Consequences

- `Ö@…` and `ö@…` are two keys, and so are two spellings of any non-ASCII local part. A sender
  who writes the same non-ASCII address in two cases gets two rows and two requests. That is
  rare, harmless, and the price of every comparison agreeing with every other.
- The readers now use the primary key index. `COLLATE NOCASE` against a `BINARY` key had to
  scan the table, once per observing row on every avatar commit.
- Rows an older build stored under a Swift-folded non-ASCII key are no longer matched by
  anything. They are not referenced by any message's `lower(fromEmail)`, so the next account
  removal deletes them; meanwhile the fetcher writes the right key beside them.
- A `kevin@` row overwritten before this change keeps the wrong answer until it goes stale
  (7 days for a 404, 30 for a photo).

## Alternatives considered

**Fold in Swift everywhere instead.** Every query would need the folded form as a bound value,
and `lower(m.fromEmail)` inside the work list, the `GROUP BY` and the cleanup would need a
custom SQL function registered on every connection. One engine doing the fold in one way is
less to get wrong than two engines agreeing.

**Register an ICU-like `lower()` or collation.** Changes what every existing key means, and
Unicode case folding still differs from Swift's `lowercased()` in places. Not worth it for an
address whose local part the server treats as opaque anyway.

**Only the per-pass guard.** It stops the loop, but leaves photos stored where the reader
never looks and lets look-alike addresses overwrite each other.

## Revisit when

The mirror links an SQLite built with ICU, or something other than SQL starts writing
`avatar` (a CardDAV contact-photo import, for instance), which must then go through the same
`lower()`.
