<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-08 — Message list

**Wave 3, after WS-04. Size: L. Parallel with WS-07, WS-09, WS-13.**

## Goal

The second column: fast at 50,000 rows, threaded or flat, entirely from the database.

## Before you start

- [../../product/ux-spec.md](../../product/ux-spec.md) — message list section
- [../../reference/ui-components.md](../../reference/ui-components.md)
- [../../decisions/0014-singleton-enumeration.md](../../decisions/0014-singleton-enumeration.md) — threading is local
- [../../architecture/concurrency.md](../../architecture/concurrency.md) — the observation pattern
- [../../product/user-stories.md](../../product/user-stories.md) — S-03

## You own

`NextcloudMail/Views/MessageList/**`

## Build

**Store**, exactly the pattern in the concurrency document — replace the observation on
selection change, never accumulate one per click:

```swift
@MainActor @Observable
final class MessageListStore {
    private(set) var rows: [MessageRow] = []
    private(set) var isMirroring: Bool = false
    func show(mailbox: Int64, view: ListView, filter: Filter?)
    func loadMore()                     // extends the window
}
```

**Row:**

```swift
NCListItem(row.senderName, subtitle: row.subject) {
    HStack { accessoryColumn; NCAvatar(displayName: row.senderName, user: row.senderEmail) }
} details: {
    NCListItemDetails(date: row.sentAt, unreadCount: row.threadUnreadCount)
}
.fontWeight(row.threadUnreadCount > 0 ? .semibold : nil)
```

Corrected as built. Unread is the thread's unread count in both views, not the drawn
message's `isSeen` ([../../decisions/0041-unread-is-the-threads-unread-count.md](../../decisions/0041-unread-is-the-threads-unread-count.md)),
and there is no `load:` because `MailStore` has no avatar reader yet.

plus a fixed-width leading accessory column for star, attachment and answered glyphs, so
rows stay aligned whether or not they have them. That column is the workaround for the
library gap noted in the component map — write down how it felt.

**Threaded and flat.** Both are queries over the same rows; switching is instant and
remembered once for the app rather than per account, which is a correction to this brief
([../../decisions/0040-list-view-is-remembered-per-app.md](../../decisions/0040-list-view-is-remembered-per-app.md)).
Threaded shows the newest message per `threadRootId` with a count badge and the thread's
unread count.

**Windowing.** The list is a window over the database. Scrolling extends it. A 50,000-row
mailbox never becomes a 50,000-element array, and "load more" has no spinner because the
rows are local.

**Date grouping** — Today / Yesterday / This week / Earlier as section headers.

**Sort** is newest first. Following the account's server-side `sort-order` preference is
not built: nothing persists that preference and the store's list queries are
`ORDER BY m.sentAt DESC`. See [../../product/ux-spec.md](../../product/ux-spec.md#message-list)
and WS-08's report for what it needs.

**Selection** — single, ⇧-range, ⌘-toggle, published for WS-10 to act on.

**States** per the UX spec: mirroring, empty, no search hits, not-downloaded-and-offline.
No spinner on a mirrored mailbox, ever.

## Acceptance

- 50,000 rows: selection to first frame **under 100 ms**, measured, number in the report.
- Scrolling stays at 60 fps (Instruments trace attached to the pull request).
- Switching threaded/flat is instant and survives relaunch.
- Rows update live when sync writes — read it in the web client, watch the weight change.
- Multi-selection works and publishes cleanly.
- Airplane mode changes nothing about any of the above.
- Zero network calls originate in this workstream. Prove it: no `NCMailNet` import.

## Out of scope

The message view (WS-09). Triage actions (WS-10 — you publish selection, they act). Search
(WS-11 — you take a `filter`, they build it).

## Report

Additionally: the measured times, and the library answers to questions 1, 2 and 5 in
[../../reference/ui-components.md](../../reference/ui-components.md) — does `NCListItem`
stay cheap at 50,000 rows, does semibold survive selection tinting, is
`NCRelativeDateFormatter`'s short form right for a mail list?
