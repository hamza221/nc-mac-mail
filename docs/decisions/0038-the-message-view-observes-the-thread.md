<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0038: The message view observes its thread, because the store cannot observe one body

**Status:** Superseded by [ADR-0045](0045-the-store-grows-the-queue-dao-and-the-readers.md)
**Date:** 2026-09-23
**Decided by:** WS-09, on finding no single-message observation in `MailStore`

## Context

Opening a message whose body has not been mirrored must not fetch and show. The view raises
that body's backfill priority, the backfill writes the database, and the view updates
because it was already observing the row
([ADR-0003](0003-local-first-full-mirror.md)). `MirrorCoordinator.prioritise(messageId:)`
returns `Void` for exactly this reason: a view that could `await` the fetch would be a view
that renders from the network.

That requires the view to be observing something that changes when the body lands.
`MailStore` has four observations — accounts, mailboxes, a message list window, a thread —
and none of them is "this message" or "this body". `body(messageId:)` is a one-shot read.

## Decision

The message view observes `observeThread(rootId:mailboxId:)` and re-reads the body when the
value reports that this message's `bodyState` changed.

It works because of a guarantee the store already gives: `MailStore.upsert(body:for:)`
writes the body row, the attachments, the search-index row **and**
`UPDATE message SET bodyState = 'present'` in one transaction. `bodyState` is one of the
columns `MessageRow` selects, so a body landing is a change to the region the thread
observation tracks, and a value arrives exactly when the body does.

The thread query is wanted anyway — the message view shows the rest of the conversation
below the body — so this adds an observation for nothing.

**The replacement is named:** `MailStore.observeBody(messageId:) -> StoreObservation<StoredBody?>`,
requested from WS-03 in WS-09's report. When it exists, `MessageViewModel.observe` loses the
`bodyState` comparison and iterates the body directly.

## Consequences

- The invariant holds today rather than after another workstream lands. `MessageViewModelTests.theViewUpdatesFromTheDatabase`
  asserts it against a real in-memory mirror: present a message with no body, write the body
  the way the backfill would, and the view renders it without anything having asked the
  network.
- A message with no `threadRootId` observes a thread that is empty. The observation still
  delivers, because GRDB tracks the region the query reads rather than the rows it returns,
  and the re-read is driven by the message row, not by the returned array. It is a weaker
  guarantee than a body observation and it is written down here rather than left as a
  surprise.
- The observation fires on every commit that touches `message`, which during a backfill is
  every batch. The view model therefore re-reads only when it is still waiting for a body or
  when this message's `bodyState` actually changed; the other values cost one array compare.
- Two observations of the same thread would be two queries. There is one: the same value
  feeds the thread strip and the body check.

## Alternatives considered

**Poll.** A timer that re-reads until the body appears. It works, it is three lines, and it
is the thing the architecture exists to avoid: the screen would be driven by a clock rather
than by the data.

**Take the row from the message list.** WS-08 already observes a window of rows, and the
selected row carries `bodyState`. Passing it down would make the detail column update for
free — until the list scrolls the selected row out of its window, at which point updates
stop with no visible cause. The detail column should not depend on the shape of another
column's query.

**Add `observeBody` to `NCMailStore` here.** The right fix, and not this workstream's file
to write ([workstreams.md](../delivery/workstreams.md#file-ownership)). Requested instead.

## Revisit when

`MailStore.observeBody(messageId:)` lands. This record is then superseded by the one-line
version of itself.
