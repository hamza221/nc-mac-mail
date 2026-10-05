<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0072: Recipient autocomplete is local-first

**Status:** Accepted
**Date:** 2026-10-03, confirmed 2026-10-04
**Decided by:** v2 roadmap; confirmed by WS-26, which implements it (`RecipientSuggestionProvider`)

## Context

The composer (ADR-0065) needs recipient autocomplete. The mirror already holds contacts
(ADR-0069) and every address seen in mirrored mail, and the server offers
`GET /api/autoComplete?term=`, which knows about Nextcloud groups and collected addresses
the mirror does not. Typing must not wait on the network.

## Decision

Recipient autocomplete is local-first.

- Sources: the contacts mirror (all enabled address books, including the system address
  book), contact groups, own identities and aliases, and addresses from mirrored mail.
- Server supplement: `GET /api/autoComplete?term=` runs only after local results are
  shown. Its results land in a `recipientSuggestion` cache table per ADR-0067, so
  Nextcloud groups and collected addresses still appear.
- Ranking: own identities last, then contacts by recent interaction, then mail-derived
  addresses by frequency.

### As built (WS-26)

- `RecipientSuggestionProvider` (app target, one per composer and login) yields the local
  list, *then* asks `ServerResultFetcher` for `autoComplete` and re-yields the merge every
  time the `recipientSuggestion` rows for the term change. The cache key is the term
  trimmed and lowercased; the server is asked from two characters on.
- Two local query shapes, chosen by size. **Contacts** are queried per keystroke through
  the `contactSearch` FTS5 index (prefix match of every typed word, enabled books of the
  login only), because the mirror's contacts are the large source and the index is
  already there. **Mirrored-mail addresses and own identities** are an in-memory index
  built by one aggregate over `messageAddress` (count and newest date per address), kept
  for five minutes and rebuilt in the background — scanning `messageAddress` per keystroke
  is the one thing that would not stay at typing speed on a large mirror, and a few
  minutes' lag in "how often" is invisible.
- "Recent interaction" for a contact is the newest mirrored message carrying the address
  (from that same in-memory index); never-mailed contacts follow, by name. A contact group
  ranks by its most recent member and expands to its mirrored members' first addresses.
- Dedup is by address, case-insensitively, first source wins; an own address (account or
  alias) is only ever an identity row, even when the system address book lists it.
- Measured (debug build, M-series Mac, file-backed store with 10,000 contacts and 2,000
  messages): in-memory index built in 10 ms; a local query takes 2–21 ms, worst on the
  one-letter term `a` (20.7 ms), against the 50 ms budget
  (`RecipientSuggestionProviderTests.tenThousandContacts`).

## Consequences

- Suggestions appear at typing speed and work offline; the server round trip only ever
  adds rows, never gates the first paint.
- Nextcloud groups and server-collected addresses still appear, cached per ADR-0067 with
  that record's staleness cost.
- The cost is two-phase results — the list can grow after the server replies — and a
  ranking that must merge four local sources with the cached server rows.

## Alternatives considered

**Server-only autocomplete (what the web client does).** Every keystroke waits on the
network, and offline composing gets no suggestions at all, despite the mirror knowing
most of the answer.

**Local-only.** Loses Nextcloud groups and server-collected addresses the mirror cannot
see.

## Revisit when

The server's autocomplete learns to return results the local merge mis-ranks badly, or
the two-phase list proves visibly janky in use.
