<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0072: Recipient autocomplete is local-first

**Status:** Proposed
**Date:** 2026-10-03
**Decided by:** v2 roadmap, to be confirmed by the owning workstream

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
