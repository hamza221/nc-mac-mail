<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0041: A row is unread when its thread has unread messages, in both views

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-08

## Context

[ux-spec.md](../product/ux-spec.md#message-list) and
[WS-08's brief](../delivery/briefs/WS-08-message-list.md) both spell the row as:

```swift
NCListItemDetails(date: row.sentAt, unreadCount: row.isSeen ? 0 : 1)
...
.fontWeight(row.isSeen ? nil : .semibold)
```

`isSeen` is the flag on the one message the row draws. In the threaded view that row is the
newest message of its thread, so a thread whose newest message has been read and whose reply
before it has not would draw as read — and it is the unread reply the person is looking for.

`MessageRow` already carries the answer. WS-03 put `threadCount` and `threadUnreadCount` on
the projection and made them 1 and 0/1 in the flat view and the real per-thread numbers in
the threaded one, so that a row renders identically in both.

## Decision

Unread is `row.threadUnreadCount > 0`, and the counter bubble takes `row.threadUnreadCount`.

One expression covers both views. In the flat view `threadUnreadCount` is `isSeen ? 0 : 1`
by construction, which is exactly the specification's rule; in the threaded view it is the
thread's real count, which is what a thread row is meant to say.

## Consequences

- No branch on `ListView` anywhere in `MessageListRow`, so the two views cannot drift into
  marking unread differently.
- The bubble in the threaded view reads "3" for a thread with three unread messages rather
  than "1", which matches the sidebar's per-mailbox count and the web client.
- The documents are corrected in the same pull request: the row snippet in
  [ux-spec.md](../product/ux-spec.md#message-list) and in the brief now reads
  `unreadCount: row.threadUnreadCount`.
- `MessageListStoreTests.threadedAndFlatAreTwoQueriesOverTheSameRows` pins it: three
  messages in one thread, one of them read, and the threaded row reports `threadCount == 3`
  and `threadUnreadCount == 2`.

## Alternatives considered

**Keep `isSeen` and add the thread count beside it.** Two numbers on the row that can
disagree — a "read" row carrying a badge that says two unread — and the person has to work
out which one means what.

**Branch on the view.** `view == .threaded ? threadUnreadCount > 0 : !isSeen`. Identical
behaviour, because the two agree in the flat view, and one more place where a future change
has to remember both.

## Revisit when

The threaded query stops filling `threadUnreadCount`, or someone shows that a thread head
being read is the thing people scan for.
