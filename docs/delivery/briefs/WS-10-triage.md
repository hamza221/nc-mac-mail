<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-10 — Triage actions, toolbar, keyboard

**Wave 4, after WS-06, WS-08, WS-09. Size: M.**

## Goal

One keystroke per decision, applied instantly, correct offline, on single messages,
multiple selections and whole threads.

## Before you start

- [../../product/ux-spec.md](../../product/ux-spec.md) — keyboard table
- [../../architecture/offline-queue.md](../../architecture/offline-queue.md) — you are its caller
- [../../product/user-stories.md](../../product/user-stories.md) — S-05
- [../../reference/api-payloads.md](../../reference/api-payloads.md) — the mutations table and trap 4

## You own

`NextcloudMail/Actions/**`, `NextcloudMail/Commands/**`

## Build

```swift
@MainActor @Observable
final class MessageActions {
    func archive(_ selection: Selection) async
    func delete(_ selection: Selection) async
    func junk(_ selection: Selection) async
    func move(_ selection: Selection, to mailboxId: Int64) async
    func toggleStar(_ selection: Selection) async
    func toggleUnread(_ selection: Selection) async
    func toggleImportant(_ selection: Selection) async
    func markAllRead(mailboxId: Int64) async
}
```

Each one builds a `MailOperation` and calls `MutationQueue.perform` — the type is
`MutationQueue`, not `OperationQueue`, because Foundation owns that name
([ADR-0044](../../decisions/0044-the-queue-type-is-not-called-operationqueue.md)). **No HTTP
in this workstream at all.** The local write updates the list through observation; you never
touch the view state directly.

Rules that are easy to get wrong:

- **Archive resolves `archiveMailboxId` from the account that owns the message**, not the
  selected account. A mixed selection across accounts produces one operation per account.
- **Junk is flags then move**, in that order, two operations.
- **Delete** moves to trash, or erases when already in trash.
- **Thread actions** use the thread endpoints, whose move parameter is `destMailboxId`
  while the message one is `destFolderId`.
- An account missing the special mailbox disables the action with an explanation, not a
  greyed button with no reason. **Every account on the live test server has
  `archiveMailboxId` null**, so this is the ordinary state rather than an edge case, and a
  disabled AppKit control cannot show a tooltip — the explanation is the context-menu item's
  title ([ADR-0050](../../decisions/0050-an-unavailable-action-says-why-in-the-menu.md)).

**Toolbar** — `NCButtonStyle.icon` with `.help` tooltips carrying the shortcut.
**Context menu** on rows, acting on the whole selection. **Move ▾** is a **popover** over the
mailbox tree with a filter field: an `NSMenu` cannot hold a `TextField`, and SwiftUI renders a
macOS `Menu` into one, so a menu and a filter field are not available at the same time
([ADR-0052](../../decisions/0052-move-is-a-popover-because-a-menu-cannot-hold-a-field.md)).
The context menu's Move stays a real submenu, flat and unfiltered.

**Commands** — a `CommandMenu` so every shortcut appears in the menu bar with its key. A
shortcut that exists only in a `keyboardShortcut` modifier is undiscoverable. The table:
`A` `S` `U` `J` `⌫` `R` `←` `→` `↑` `↓` `⌘F` `⌘⇧F` `⌘P`.

Two of those are **not** registered as menu items. `↑` and `↓` already move the selection in
`List(selection:)`, and a key equivalent is matched ahead of the first responder, so binding
them would take the arrow keys from the list, the search field and the message body at once.
`⌘F` and `⌘⇧F` are registered only once a search handler is wired, because `.searchable`
binds `⌘F` itself and a second binding leaves one of the two dead. Both keys are listed in
Help ▸ Keyboard Shortcuts either way
([ADR-0049](../../decisions/0049-the-arrow-keys-stay-with-the-list.md)).

**After acting on the selected message**, selection advances to the next one — that is what
makes a triage pass a rhythm rather than a sequence of clicks. Advance direction follows
the sort order.

**Undo** via the system `UndoManager` for the last action, mapped to its inverse operation.
`⌘Z` after an accidental archive is the difference between trust and fear, and the queue
already makes it cheap.

## Acceptance

- Every shortcut works, appears in the menu bar, and is listed in Help.
- Acting on a 200-message selection is one batch, and the list updates in one frame.
- Every action works offline, survives quit, and reaches the server on reconnect.
- Archive on a mixed-account selection routes each message to its own archive.
- Junk sets the flag **and** moves.
- `⌘Z` undoes the last action, including offline.
- Selection advances after acting, in sort order, and stops sensibly at the end.
- An account with no archive mailbox disables Archive with a reason the user can read.

## Out of scope

The queue itself (WS-06). List rendering (WS-08). Snooze, tags, quick actions — all post-v1.

## Report

Additionally: whether undo through the operation queue was as cheap as it looks here, and
what a 200-message batch does to the drain.
