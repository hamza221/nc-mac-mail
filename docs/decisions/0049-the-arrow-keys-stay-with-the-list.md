<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0049: `↑` and `↓` stay with the list; every other key is a menu item

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-10, writing the command menu

## Context

[ux-spec.md](../product/ux-spec.md#keyboard) lists thirteen keys and asks for all of them to
be registered as `Commands`, "so they appear in the menu bar with their shortcuts — a
shortcut that exists only in a `keyboardShortcut` modifier is undiscoverable". The
[WS-10 brief](../delivery/briefs/WS-10-triage.md) repeats the table, arrows included.

A menu item's key equivalent is matched by AppKit before the key reaches the first responder.
For `A` or `⌘P` that is what we want. For `↑` and `↓` it takes the arrow keys away from
everything else in the window at once: `List(selection:)` moves the selection with them,
`NSTableView` scrolls with them, a text field moves its insertion point with them, and the
message body scrolls with them. Registering them would replace four working behaviours with
one.

`⌘F` has the mirror-image problem. WS-11 puts `.searchable` on the message list, which binds
`⌘F` itself. A second binding in the menu bar means one of the two never fires, and which one
depends on responder order rather than on anything written down.

## Decision

`↑` and `↓` are not registered. They are `List`'s, and the shortcut window documents them as
the platform's rather than pretending they are ours.

`←` and `→` — previous and next message — *are* registered. Nothing else in a three-column
reading window binds them, and they are the keys that make a triage pass work without the
mouse.

`⌘F` and `⌘⇧F` are registered **only when a search handler is wired** into `TriageContext`.
Absent one, the two items are left out of the menu entirely rather than shown disabled, so
nothing shadows `.searchable`.

## Consequences

- Every key in the specification's table works. Two of them work because the platform already
  does it, and the shortcut window says so.
- `KeyboardShortcutRow.platform` is the only written record of `↑`, `↓`, `⇧`-click and
  `Space`, and a test asserts the window lists them.
- WS-11 turns `⌘F` on by assigning `TriageContext.search`. Until then the Find items are
  absent, which is honest: nothing can answer them.
- Untested without a GUI. The single-letter keys (`A`, `S`, `U`, `J`, `R`) are matched by
  AppKit ahead of the first responder, which is right in the list and wrong in a text field.
  If they turn out to swallow typing in the search field, the fix is a focus condition on the
  command items, not a change to this decision.

## Alternatives considered

**Register the arrows anyway and re-implement list navigation.** Moving a selection, keeping
the moved row visible, and handling the section headers is `NSTableView`'s job, done well,
for free.

**Bind the arrows only while the list has focus.** SwiftUI has `@FocusedValue` for exactly
this, and it would work. It is more machinery than a key that already does the right thing
needs.

## Revisit when

The list stops being a `List`, or a second view in the window wants the arrow keys.
