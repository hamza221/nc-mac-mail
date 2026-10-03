<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0052: Move ▾ is a popover in the toolbar, because a menu cannot hold a filter field

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-10

## Context

The [WS-10 brief](../delivery/briefs/WS-10-triage.md) and
[ux-spec.md](../product/ux-spec.md#message-view) both ask for "**Move ▾** … a `Menu` over the
mailbox tree with a filter field".

SwiftUI renders a macOS `Menu` into an `NSMenu`, whose items are `NSMenuItem`s. Buttons,
toggles, pickers, dividers and submenus map onto one; a `TextField` does not. A filter field
and an `NSMenu` are two different containers, and an account with sixty folders is exactly
the case the filter was asked for.

## Decision

The toolbar's Move ▾ is a **popover** containing the filter field and the folder list. The
list keeps the mailbox tree's order and indentation, drops the indentation while a filter is
running — a match whose parent does not match would otherwise be indented under nothing — and
offers only folders a message can land in, so a `\noselect` container row is absent rather
than present and broken.

The **context menu's** Move stays a real submenu, flat, with no filter. A context menu has
nowhere to put a field, and the toolbar is one click away.

## Consequences

- The filter the specification asked for exists, with the keyboard, in the place the
  specification asked for it.
- Two Move surfaces behave slightly differently: one filters, one does not.
- `ux-spec.md`'s "Move ▾ is a `Menu`" is now wrong in its choice of container. The correction
  is a request in WS-10's report rather than an edit, because three workstreams are editing
  that file concurrently and the sentence is one line of a section another of them owns.
- **Not verified in a running window.** There is no GUI in this environment. The reasoning is
  about what `NSMenu` can hold, not about something that was watched failing.

## Alternatives considered

**Nested submenus over the tree, no filter.** Works, and is what the context menu does. Sixty
folders three levels deep with no way to type a name is the case the filter was for.

**A sheet.** Modal, for picking a folder. Heavier than the action.

## Revisit when

SwiftUI grows a menu that can hold a text field, or the folder picker becomes a sheet shared
with a future Copy-to.
