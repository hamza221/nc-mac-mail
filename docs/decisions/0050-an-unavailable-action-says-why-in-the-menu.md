<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0050: An unavailable action says why in the menu, because a disabled button cannot

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-10, writing the toolbar

## Context

The [WS-10 brief](../delivery/briefs/WS-10-triage.md) is explicit: "An account missing the
special mailbox disables the action with an explanation, not a greyed button with no reason."
This is not a rare state. The live test account has `archiveMailboxId` null, and
[offline-queue.md](../architecture/offline-queue.md) says a server with no archive folder is
the common case.

The obvious answer is `.help(reason)` on the toolbar button. It does not work. A disabled
AppKit control does not track the pointer, so its tooltip never appears — the one state that
needs the explanation is the one state that cannot show it.

The alternatives that do work are all worse in isolation. A modal contradicts
[ux-spec.md](../product/ux-spec.md#errors-and-the-rule-about-them). An inline banner in the
message pane costs a row of chrome for a condition most people never meet. Leaving the button
enabled and failing on click teaches people that buttons lie.

## Decision

`TriageAvailability` carries the sentence, and three surfaces show it:

- the toolbar button is **disabled**, with the reason in `.help` and in `accessibilityHint`,
  which is what VoiceOver reads even though the pointer cannot reach it;
- the **context menu item's title becomes the reason** — "Account 0 has no Archive folder on
  the server." in place of "Archive" — and a disabled `NSMenuItem` does render its title;
- the menu-bar item is disabled with its ordinary title, because a menu bar whose item names
  change under the pointer is worse than one that is briefly grey.

The reason is a sentence, not an error case, because its only reader is a person.

## Consequences

- The explanation is one right-click away, always, with no new chrome.
- `availability` is computed asynchronously and stored, since resolving an account's archive
  folder is a database read and a view body cannot await one. It is refreshed from
  `.task(id:)` on the selection.
- A screen reader gets the reason from the hint without the pointer problem existing at all.
- The context menu's title changes shape between states, which is unusual. It is the only
  surface that can carry the text.

## Alternatives considered

**A `NCNoteCard(.warning)` in the message pane.** Permanent chrome for an occasional
condition, and it belongs to WS-09's file rather than this one.

**An alert on click, with the button left enabled.** A dialogue for something the app cannot
retry, which is the one rule [ux-spec.md](../product/ux-spec.md#errors-and-the-rule-about-them)
states outright.

## Revisit when

The message pane grows a place for a standing note, or AppKit starts showing tooltips on
disabled controls.
