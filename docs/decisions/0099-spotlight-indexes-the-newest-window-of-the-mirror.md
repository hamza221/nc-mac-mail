<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0099: Spotlight indexes the newest 5 000 messages and every contact

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-42

## Context

§10 "Unified search" maps to Spotlight. The mirror is complete (ADR-0003) and can hold
hundreds of thousands of messages; in-app search (FTS5, ADR-0011) already covers all of
them, bodies included. Spotlight has to be kept equal to the mirror from store observations
— the rule is "engines write the store, everything else observes it" — and an observation
re-reads its whole query on every write to the tables it reads.

The store has no change feed (no "rows changed since"), so any observation-based indexer
diffs a value it holds against the next one.

## Decision

- `SpotlightIndexer` (an actor in `NextcloudMail/System/`) mirrors **a window**: the newest
  `SpotlightIndexer.messageLimit` = 5 000 messages across every mailbox, flat, and every
  contact card of every signed-in login (groups excluded).
- It is fed by `observeMessages(query: every mailbox, .flat, .newest, 0..<5000)` and one
  `observeContacts(loginId:)` per login, each throttled to one value per second, keeping
  only the newest.
- Each value is diffed against what was last written. Changed indexed fields (subject,
  preview, sender, date; a card's names, organisation, addresses) are rewritten; an item
  that left the window — deleted from the mirror, pushed past the limit, its login signed
  out — is deleted from Spotlight. A flag change writes nothing.
- The first value of each domain after launch replaces the domain (`deleteSearchableItems
  (withDomainIdentifiers:)`), because the diff state is not persisted.
- Envelope fields only: subject, the server's preview text the list already shows, sender,
  date. No body, no recipient list.
- Identifiers are `message:<local id>` / `contact:<local id>`; opening a result routes
  through `SystemLink` to the same selection a click makes.

## Consequences

- A message older than the newest 5 000 is found by in-app search, not by Spotlight.
- Steady-state cost is one 5 000-row read per second at most while sync writes, and no
  Spotlight writes unless something visible changed. A launch reindexes the window once.
- Spotlight's store holds subjects, previews and senders. That is the same exposure
  ADR-0006 accepts for envelopes on disk; Spotlight's index is per-user.
- Spotlight needs no entitlement; the sandboxed app writes `CSSearchableIndex.default()`.
  The tests use an in-memory `SpotlightIndexing` because what matters is which items are
  written and deleted when.

## Alternatives considered

**Index the whole mirror.** Either an observation of every row (hundreds of thousands per
value) or a change feed the store does not have. Rejected until the store grows one.

**Index on the sync engine's writes.** Puts Spotlight inside NCMailSync, which must not
know about the app's system integration, and misses local writes (triage, deletes).

**Persist the diff state.** Saves one reindex per launch at the cost of a second copy of
5 000 envelopes' worth of state that can drift from Spotlight's.

## Revisit when

The store gains a change feed, or users report not finding older mail through Spotlight.
