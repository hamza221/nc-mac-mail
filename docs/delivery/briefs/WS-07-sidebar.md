<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-07 — Sidebar: accounts and mailbox tree

**Wave 3, after WS-04. Size: M. Parallel with WS-08, WS-09, WS-13.**

## Goal

The first column: every account, every mailbox, in the right order, with unread counts,
drawn from the database and built out of `NextcloudUI`.

## Before you start

- [../../product/ux-spec.md](../../product/ux-spec.md) — sidebar section
- [../../reference/ui-components.md](../../reference/ui-components.md)
- [../../decisions/0007-subscribed-mailboxes-only.md](../../decisions/0007-subscribed-mailboxes-only.md)
- `NextcloudShowcase/Showcase.swift:586` — `MailScreenDemo`, the reference composition

## You own

`NextcloudMail/Views/Sidebar/**`, `Packages/NCMailCore/Sources/NCMailCore/MailboxTree.swift`

## Build

**`MailboxTree`** — a pure function in `NCMailCore`, and the most testable thing in the app:

```swift
public struct MailboxNode: Sendable, Identifiable {
    public let mailbox: Mailbox
    public let children: [MailboxNode]
    public let depth: Int
}

public enum MailboxTree {
    public static func build(from mailboxes: [Mailbox], delimiter: String?) -> [MailboxNode]
}
```

Rules, each a test case:

- Split `name` on `delimiter`; the display name is the **last component**, because the
  server's `displayName` is the full path.
- Order: inbox, drafts, sent, archive, junk, trash, then the rest alphabetically,
  locale-aware and case-insensitive.
- A child whose parent has no row of its own gets a synthetic container node.
- `\noselect` mailboxes are containers: expandable, not selectable.
- A `nil` or empty delimiter means a flat namespace.
- Unicode and IMAP modified-UTF-7 names must not break the split.

**The view.** `List(selection:)`, a section per account in server `order`:

```swift
NCNavigationCaption(account.name) { Menu { … } }        // refresh, storage, sign out
NCNavigationItem(node.displayName, icon: icon(for: node), count: node.unread)
```

with `DisclosureGroup` for children, expansion persisted per mailbox in `meta`.

Icons come from one `MailSymbol` mapping, not scattered `Image(systemName:)` — inbox, sent,
drafts, archive and several others are **not** in the library catalogue, so they are SF
Symbols for now behind that one type. See the gap list in
[../../reference/ui-components.md](../../reference/ui-components.md).

Unsubscribed mailboxes render in secondary text, since they open but are not mirrored.

**Footer**, priority order: backfill progress → offline → pending-actions count → nothing.
Idle chrome is noise; when everything is fine the footer is empty.

**Context menu:** Mark all as read, Refresh, Get info.

## Acceptance

- `MailboxTree` is covered by tests including every rule above; it never touches I/O.
- An account with 200 mailboxes four levels deep renders correctly and quickly.
- Unread counts match the web client, and update live when sync writes.
- Selection drives the list column; expansion state survives relaunch.
- Selecting a `\noselect` container is impossible.
- The footer shows exactly one thing at a time, and nothing when idle.
- VoiceOver reads a mailbox row as name plus unread count.

## Out of scope

The message list (WS-08). Settings (WS-12). The window and theme (WS-13). Progress
computation (WS-04 publishes it; you render it).

## Report

Additionally, for the library: did `NCNavigationItem` compose inside `DisclosureGroup`
without fighting? Did the brand tint and the macOS selection highlight agree? Which icons
you had to substitute — that list is the most concrete feedback this workstream produces.
