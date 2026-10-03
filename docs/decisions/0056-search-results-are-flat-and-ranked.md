<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0056: Search results are a flat ranked list, whatever the list is set to

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-11

## Context

The message list has two views, flat and threaded, and the choice is remembered
([ADR-0040](0040-list-view-is-remembered-per-app.md)). Search results replace the rows of
that same list, so they inherit a `ListView` whether or not it means anything to them.

It does not mean the same thing. The threaded list shows the newest message of each thread
with the thread's size and unread count, ordered by date. Search orders by relevance. Put
the two together and the count on a row reads as "messages in this thread", while what the
reader is being shown is "the best-ranked message that happens to be in this thread" — two
different facts drawn identically.

## Decision

Search always produces flat rows: `threadCount` is 1 and `threadUnreadCount` is 0 or 1 from
the message's own `isSeen`, the same values the flat list produces. The `ListView` setting
is ignored while a search is running and takes effect again when the field is cleared.

Ordering is `bm25(messageSearch, 10.0, 3.0, 1.0, 8.0)` ascending, with `sentAt DESC`
breaking ties.

## Consequences

- A thread whose messages each match is several rows. That is the honest answer: they are
  several matches, and collapsing them would hide the one the reader wanted behind the one
  that happens to be newest.
- The row draws with no thread bubble, because the count really is one.
- The view picker in the toolbar is inert under a search. Nothing hides it, so the state is
  visible rather than silently overridden, and the moment the field is cleared the list is
  back to whatever it said.
- Relevance beats recency, which is the point of ranking at all. Against the live account,
  a search for a word appearing in 20 messages put all 11 of the ones carrying it in the
  subject above the 9 that only mention it in the body; the unindexed order had a body-only
  hit in sixth place.

## Alternatives considered

**Group hits by thread.** Fewer rows for a chatty mailbox, and it needs a rule for what a
thread's rank is — the best of its messages, the sum, the newest? Each is defensible and
each surprises somebody. The cost is also real: grouping a ranked result set means scoring
everything, then grouping, then re-ranking.

**Follow the list's setting.** One fewer special case, and a thread count next to a ranked
hit that means something else.

**Order by date, not relevance.** Simple, and it throws away the reason `bm25` is in the
schema. At forty thousand messages a date-ordered result for a common word is the same as
no search at all.
