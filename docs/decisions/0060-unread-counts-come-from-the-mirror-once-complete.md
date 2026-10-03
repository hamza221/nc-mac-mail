<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0060: A mailbox's unread count comes from the mirror once the mirror is complete

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** first manual QA pass, after opening a message marked it read and the
sidebar's count did not move

## Context

`mailbox.unreadCount` holds the server's figure. Only a folder-list refresh (hourly) or a
stats call writes it. Every local change leaves it alone: opening a message, `U`, Mark all
as read, a move, a delete, and all of these while offline. The sidebar drew that column, so
it showed a number that the list right next to it contradicted.

## Decision

`MailStore`'s mailbox fetch (`observeMailboxes`, `mailboxes(accountId:)`) replaces
`unreadCount` with `count(*) WHERE isSeen = 0` from `message` for every mailbox that is
mirrored and has `envelopesComplete`. For any other mailbox the server's figure stands. The
column itself is never rewritten.

## Consequences

- The count moves in the same frame as the bold weight on the row, offline included,
  because both read the same rows. The observation now tracks `message`, so the sidebar
  re-fetches when a flag changes.
- A mailbox still in stage 1 shows the server's count, then switches to the local one when
  enumeration finishes. Those agree unless something changed in between.
- Cost: one grouped count per sidebar fetch, served by `idxMessageMailboxSeen`. It grows
  with the account's unread messages, not with its size.

## Alternatives considered

**Adjust the column in the mutation transaction.** That covers our own writes, but every
writer (flag toggles, moves, deletes, sync's `changedMessages`) has to remember to do it, and
the next server refresh can overwrite a correct local number with one taken before the
drain. Counting can't drift.

**Always count locally.** This undercounts a mailbox that is still enumerating, and shows
zero for one that isn't mirrored.

## Revisit when

Unsubscribed mailboxes become mirrored, or the server reports per-mailbox counts on every
sync response.
