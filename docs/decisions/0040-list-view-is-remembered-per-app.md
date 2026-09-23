<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0040: Threaded or flat is remembered once for the app, not once per account

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-08, against the wording in the UX specification

## Context

[ux-spec.md](../product/ux-spec.md#message-list) and
[WS-08's brief](../delivery/briefs/WS-08-message-list.md) both say the threaded/flat choice
is "remembered per account".

WS-13 has already built the persistence. `NavigationState` owns three `meta` keys —
`navigation.selectedAccountId`, `navigation.selectedMailboxId`, `navigation.listView` — and
the last of those is one row, not one row per account. `NavigationState.swift` is WS-13's
file ([workstreams.md](../delivery/workstreams.md#file-ownership)), so WS-08 either uses the
key that exists, asks WS-13 for an account-scoped one, or writes a second key of its own
from the message list.

## Decision

The message list writes through `NavigationState.setListView(_:)` and the choice is
remembered once for the app.

Threaded or flat is a reading habit, not a property of a mailbox. Somebody who reads
conversations reads them in both accounts, and the case for splitting it is that one
account's mail threads and another's does not — which is a reason to switch views
occasionally, not a reason for the app to switch on the user's behalf when they click an
account.

## Consequences

- One `meta` row, one setter, and the value survives a relaunch because
  `NavigationState.load()` already reads it. `NavigationStateTests` covers both directions
  and needed no change.
- Switching account does not change the list's shape, which also means selecting an account
  never reshuffles a list someone was reading.
- The documents that said "per account" are corrected in the same pull request, per the
  house rule: [ux-spec.md](../product/ux-spec.md#message-list) and the brief.
- If it turns out to be wrong, the change is small and lives in one file that is not this
  workstream's: `navigation.listView` becomes `navigation.listView.<accountId>` inside
  `NavigationState`, and the message list is unchanged because it only ever calls the setter.

## Alternatives considered

**A second `meta` key written from the message list.** `MailStore.setMetaValue` is public
and WS-08 could have written `messageList.listView.<accountId>` without touching WS-13's
file. It would also have given the app two places that believe they own the list view, and
`NavigationState.listView` would have been the one that was wrong. Two sources of truth for
one preference is a worse outcome than a preference with a narrower scope.

**Block on WS-13 adding an account-scoped key.** The brief says to do everything that is not
blocked rather than idle, and nothing about this blocks: the list works, the choice
persists, and the difference is one `meta` key's name.

## Revisit when

Somebody reports wanting threaded mail in one account and flat in another. It is a one-file
change inside `NavigationState` when they do.
