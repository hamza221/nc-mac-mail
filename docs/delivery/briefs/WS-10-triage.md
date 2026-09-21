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

Each one builds a `MailOperation` and calls `OperationQueue.perform`. **No HTTP in this
workstream at all.** The local write updates the list through observation; you never touch
the view state directly.

Rules that are easy to get wrong:

- **Archive resolves `archiveMailboxId` from the account that owns the message**, not the
  selected account. A mixed selection across accounts produces one operation per account.
- **Junk is flags then move**, in that order, two operations.
- **Delete** moves to trash, or erases when already in trash.
- **Thread actions** use the thread endpoints, whose move parameter is `destMailboxId`
  while the message one is `destFolderId`.
- An account missing the special mailbox disables the action with an explanation, not a
  greyed button with no reason.

**Toolbar** — `NCButtonStyle.icon` with `.help` tooltips carrying the shortcut.
**Context menu** on rows, acting on the whole selection. **Move ▾** is a `Menu` over the
mailbox tree with a filter field.

**Commands** — a `CommandMenu` so every shortcut appears in the menu bar with its key. A
shortcut that exists only in a `keyboardShortcut` modifier is undiscoverable. The table:
`A` `S` `U` `J` `⌫` `R` `←` `→` `↑` `↓` `⌘F` `⌘⇧F` `⌘P`.

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
