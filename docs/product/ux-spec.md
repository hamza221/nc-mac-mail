<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# UX specification

*Screen by screen, including the states people actually hit. Component signatures are in
[../reference/ui-components.md](../reference/ui-components.md).*

## Window

One `NavigationSplitView`, three columns, the macOS shape every mail client uses.

```
┌───────────────┬──────────────────────┬──────────────────────────────────┐
│ SIDEBAR       │ MESSAGE LIST         │ MESSAGE                          │
│ 200–320       │ 280–480              │ remaining, min 420               │
│               │                      │                                  │
│ ▾ Work        │ ○ Sookie St. James   │ The Dragonfly opening menu       │
│   Inbox    7  │   The Dragonfly…  3m │ ● Sookie St. James  ·  14:22     │
│   Sent        │ ● Michel Gerard      │ to Lorelai Gilmore               │
│   Drafts      │   Front desk rota 2h │ ──────────────────────────────── │
│   Archive     │   Luke Danes         │ I moved the risotto to the       │
│   Junk        │   Re: coffee     Tue │ second course, tell me what…     │
│   Trash       │                      │                                  │
│ ▾ Personal    │                      │ 📎 menu.pdf  179 KB              │
│   Inbox    2  │                      │                                  │
│ ─────────────  │                      │                                  │
│ ⟳ 12,431/48,902                     │                                  │
└───────────────┴──────────────────────┴──────────────────────────────────┘
```

Column widths persist, approximately: SwiftUI's `navigationSplitViewColumnWidth(min:ideal:max:)`
has no binding that reports back what a drag resized a column to, so WS-13 tracks each
column's rendered width with a `GeometryReader` and feeds it back in as the next launch's
`ideal`. It is a measurement, not a restoration the framework promises, and it was not
verified against a live drag in this environment (no GUI). Collapsing the sidebar is the
system's behaviour, not ours. Window size and the selected mailbox restore on launch — state
restoration, not a preference.

## Sidebar

`List(selection:)` with a section per account, in server `order`.

- **Account header** — `NCNavigationCaption(account.name)`. A trailing `action:` menu
  carries Refresh, Storage… and Sign out.
- **Mailbox row** — `NCNavigationItem(displayName, icon:, count: unread)`, nested in
  `DisclosureGroup` where the tree has children. Expansion state persists per mailbox.
- **Order** — special roles first, in the order people expect: Inbox, Drafts, Sent,
  Archive, Junk, Trash; then the rest alphabetically, case- and locale-insensitive.
  `MailboxTree` is a pure function and is unit-tested
  ([../delivery/testing-strategy.md](../delivery/testing-strategy.md)).
- **Unsubscribed mailboxes** are shown in secondary text with no mirror, because they still
  work, just without a local copy ([../decisions/0007-subscribed-mailboxes-only.md](../decisions/0007-subscribed-mailboxes-only.md)).
- **`\noselect` mailboxes** are container rows: expandable, not selectable.
- **Footer** carries, in priority order, whichever is true:
  1. backfill progress — `ProgressView` + "12,431 of 48,902";
  2. "Offline" when there is no route;
  3. "2 actions waiting" when the queue has visible failures, tappable to a popover;
  4. nothing at all when everything is fine. Idle chrome is noise.

**Context menu per mailbox:** Mark all as read, Refresh, Get info (counts, mirror state).

## Message list

`List(selection:)`, multi-selection enabled, windowed over the database.

Row is `NCListItem` with the Mail shape:

```swift
NCListItem(senderDisplayName, subtitle: subject) {
    HStack { accessoryColumn; NCAvatar(displayName: senderDisplayName, user: senderEmail) }
} details: {
    NCListItemDetails(date: sentAt, unreadCount: row.threadUnreadCount)
} trailing: {
    NCCounterBubble(count: row.threadCount > 1 ? row.threadCount : 0, role: .neutral, label: .decorative)
}
.fontWeight(row.threadUnreadCount > 0 ? .semibold : nil)
```

- **Unread** is the semibold weight plus the counter bubble, matching the showcase. It is the
  *thread's* unread count, not the drawn message's `isSeen`, which is one rule for both views
  rather than two ([../decisions/0041-unread-is-the-threads-unread-count.md](../decisions/0041-unread-is-the-threads-unread-count.md)).
- **No avatar photo yet.** `NCAvatar` takes no `load:`, so it draws coloured initials: the
  `avatar` table exists and `MailStore` has no reader for it. WS-08's report carries the
  request.
- **Starred** shows `star` in the leading accessory column; **attachments** show a clip;
  **answered** a reply arrow. Three optional glyphs in a fixed-width column so rows stay
  aligned — and the reason the library's leading slot is noted as a gap.
- **Threaded view** shows the newest message of each thread with a count badge; flat shows
  every message. Toolbar `Picker`, remembered once for the app rather than per account
  ([../decisions/0040-list-view-is-remembered-per-app.md](../decisions/0040-list-view-is-remembered-per-app.md)).
- **Date grouping** — Today / Yesterday / This week / Earlier as section headers. Cheap,
  and it is how people navigate a long list.
- **Sort** is newest first, and does **not** yet follow the account's server-side
  `sort-order` preference. Nothing persists that preference — `SyncScheduler` reads it and
  keeps it in memory ([../decisions/0036-sort-order-decides-the-cursor.md](../decisions/0036-sort-order-decides-the-cursor.md))
  — and the store's list queries are `ORDER BY m.sentAt DESC` with the index that makes them
  fast. Making the two clients agree needs a column on `account` and an ordering parameter on
  `observeMessages`; WS-08's report carries the request.
- **Selection** — click selects, ⇧-click extends, ⌘-click toggles. Toolbar and context menu
  act on the whole selection.

**States**

| State | What is shown |
| --- | --- |
| Mirrored, has messages | The list |
| Mirroring, first page in | The list, growing. No spinner |
| Mirrored, empty mailbox | `ContentUnavailableView("No messages", …)`, with the icon through `MailSymbol` |
| Search, no hits | `ContentUnavailableView.search` with the query |
| Mailbox unselectable | Never reachable: the row does not select |
| Never mirrored, offline | "Not downloaded yet" plus what will happen on reconnect |

## Message view

Native chrome, WebView body ([../architecture/rendering.md](../architecture/rendering.md)).

```
Subject                                                    .title2, semibold
● Sender Name <sender@example>                 14:22       NCUserBubble, .medium
to Lorelai Gilmore, Michel Gerard  ▾                       NCChip each, collapsed past 3
───────────────────────────────────────────────────────────
[ NCNoteCard .warning — remote content blocked ]           only when applicable
───────────────────────────────────────────────────────────
  body
───────────────────────────────────────────────────────────
📎 menu.pdf 179 KB   📎 rota.ods 22 KB     [Save all]      only when applicable
```

- **Toolbar**: Archive, Delete, Junk, Move ▾, Star, Mark unread, Refresh. `NCButtonStyle.icon`
  with `.help` tooltips carrying the shortcut.
- **Thread** — siblings listed below, collapsed, newest last, with the selected one
  expanded. Clicking a sibling expands it in place; it does not navigate.
- **Phishing and security** — a `NCNoteCard(.error)` when the server's `phishingDetails`
  says so; a small verified badge for a valid DKIM or S/MIME signature. Absent when there
  is nothing to say. A permanent green badge teaches people to ignore badges.
- **Attachments** — a row of chips; click downloads through a save panel; images preview in
  Quick Look.

**States**

| State | What is shown |
| --- | --- |
| Body mirrored | The message |
| Body not mirrored, online | Header immediately, body placeholder for the moment it takes; the fetch is queued at the head |
| Body not mirrored, offline | Header, and "This message has not been downloaded yet. It will be available when you are back online." |
| Body fetch failed | The same, plus Retry |
| Nothing selected | `ContentUnavailableView("No message selected")` |

Note the shape of the second row: the header is always available, because the envelope is
always mirrored. The app never shows an empty screen where a message should be.

## Search

`.searchable` on the message list, ⌘F.

- Results replace the list, as you type, from the local index — no debounce theatre beyond
  the one frame it takes.
- Scope control: **This mailbox** / **All mail** (across accounts).
- Matches highlighted with `NCHighlightText`.
- Result rows carry the mailbox name, since "all mail" spans folders.
- Footer states the coverage while the backfill is incomplete: "Searching 31,204 of 48,902
  downloaded messages." Honest, and it disappears when the mirror completes.
- Escape clears and returns to the mailbox.

## Settings

`Settings` scene, `Form` + `.formStyle(.grouped)`, three tabs.

**General** — default list view (threaded/flat), mark-as-read delay, appearance note.

**Accounts** — one row per account: name, address, mirror state, last sync, Sign out. A
note that accounts are added in the web client, with a button that opens it, because a
blank space where account creation should be is worse than an explanation.

**Storage** — the panel [ADR-0008](../decisions/0008-no-automatic-eviction.md) requires:

```
Work · lorelai@dragonfly.example
  48,902 messages · 812 MB local · mirror complete
  [Remove local copies]  [Re-download]  [Check for missing messages]

Personal · lorelai@example.com
  3,204 messages · 61 MB local · downloading bodies (2,104 remaining)   [Pause]
```

Every destructive confirmation says it removes **local copies only** and does not touch the
server.

## Keyboard

Matching the web client where it costs nothing, since people use both.

| Key | Action |
| --- | --- |
| `↑` `↓` | Move selection in the list |
| `←` `→` | Previous / next message |
| `A` | Archive |
| `S` | Toggle star |
| `U` | Toggle unread |
| `J` | Junk |
| `⌫` | Delete (trash, or erase when in trash) |
| `R` | Refresh |
| `⌘F` | Search |
| `⌘⇧F` | Search all mail |
| `⌘P` | Print message |
| `⇧` + click | Extend selection |
| `Space` | Scroll the message body |
| `⌘,` | Settings |

Registered as `Commands` so they appear in the menu bar with their shortcuts — a shortcut
that exists only in a `keyboardShortcut` modifier is undiscoverable.

## Errors, and the rule about them

One rule, and it is the difference between a calm app and a nervous one:

> **Nothing that the app can retry gets a dialogue.**

- Offline → one sidebar indicator. Not a banner, not a sheet.
- Sync failure on one mailbox → that mailbox's row shows it on hover, and Get info explains.
- Queued actions failing → one aggregate indicator after five attempts
  ([../architecture/offline-queue.md](../architecture/offline-queue.md)).
- Authentication lost (401) → this one **is** modal, because nothing works until it is
  fixed: "Your session has expired. Sign in again."
- Disk full → surfaced once in the storage panel with the number of bytes needed.

## Accessibility

- Every control has a label; decorative icons are marked decorative. The library makes this
  mandatory at the type level.
- Full keyboard navigation, visible focus, no mouse-only affordance.
- VoiceOver rotor works over the list, and a row reads as "unread, from Sookie St. James,
  The Dragonfly opening menu, 3 minutes ago".
- Dynamic Type throughout the native chrome; the message body keeps its own sizing, with
  ⌘+/⌘− to zoom it.
- Reduce Motion honoured; Increase Contrast honoured through the library's contrast maths.
- Nothing is conveyed by colour alone: unread is weight plus a bubble, starred is a glyph.
