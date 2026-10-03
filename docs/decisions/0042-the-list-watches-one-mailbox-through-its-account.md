<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0042: The message list watches one mailbox through its account's mailbox observation

**Status:** Superseded by [ADR-0045](0045-the-store-grows-the-queue-dao-and-the-readers.md)
**Date:** 2026-09-23
**Decided by:** WS-08, on finding no single-mailbox observation in `MailStore`

## Context

There is no spinner on a message list
([ux-spec.md](../product/ux-spec.md#message-list)). An empty list means one of three things
and they read differently: the mailbox is still being enumerated, the mailbox is mirrored and
empty, or the mailbox has never been mirrored and there is no route to fetch it now. The
column that tells them apart is `mailbox.envelopesComplete`, and it changes while the list is
on screen — stage 1 finishing is exactly the moment "Downloading messages" has to become
"No messages".

`MailStore` observes accounts, an account's mailboxes, a message-list window and a thread.
`mailbox(id:)` exists and is a one-shot read. There is no `observeMailbox(id:)`.

## Decision

`MessageListStore` reads the mailbox once to learn its `accountId`, then iterates
`observeMailboxes(accountId:)` and picks its own row out of each value.

It is a second observation alongside the rows, replaced with them on every selection change.

## Consequences

- The three empty states are driven by the database rather than by a snapshot taken when the
  mailbox was selected. `MessageListStoreTests.mirroringThenEmpty` asserts the transition:
  select an empty mailbox, see `.mirroring`, stamp the cursor complete, see `.emptyMailbox`,
  with nothing polling.
- The observation re-fetches every mailbox of the account whenever any of them changes,
  which during a backfill is often. It is a few dozen rows off the main actor and the value
  is an array compare; it is not on the 100 ms path, which the rows are.
- The rows arrive before the mailbox row does, because the row observation starts first. That
  is the right way round: the mirror state only decides what to say when there are no rows.
  `presentation` returns `.rows` while `mailbox` is still nil, so selecting a mirrored
  mailbox never flashes "Downloading messages" on its way to the list.
- **The replacement is named:** `MailStore.observeMailbox(id:) -> StoreObservation<MailboxRecord?>`,
  requested from WS-03 in this workstream's report. `observeMailbox(id:)` is also what
  WS-07's sidebar wants for a single row's unread count and what WS-12's storage panel wants.

## Alternatives considered

**Read `mailbox(id:)` once when the mailbox is selected.** One line, and wrong in the one
case that matters: a mailbox selected while it is still enumerating would say "Downloading
messages" forever, because nothing would ever tell it otherwise.

**Re-read the mailbox each time the rows change.** Cheap, and it fails for an empty mailbox,
which is the only case the mirror state is consulted for: no rows means no row change means
no re-read.

**Add `observeMailbox(id:)` to `NCMailStore` here.** The right fix, and not this
workstream's file to write ([workstreams.md](../delivery/workstreams.md#file-ownership)).
Requested instead, exactly as WS-09 did for `observeBody(messageId:)`
([ADR-0038](0038-the-message-view-observes-the-thread.md)).

## Revisit when

`MailStore.observeMailbox(id:)` lands. `MessageListStore.observeMailbox(id:)` then loses its
preliminary read and its `first(where:)`, and this record is superseded.
