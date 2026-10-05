<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-25 — App shell v2

**Wave 2 end, after WS-21, WS-22, WS-23, WS-24. Size: M.**

## Goal

Every engine starts, and the navigation model knows contacts, outbox and virtual mailboxes.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0053-settings-builds-its-own-short-lived-coordinators.md](../../decisions/0053-settings-builds-its-own-short-lived-coordinators.md) — the on-demand pattern for `SettingsCommands`
- [../../decisions/0070-contacts-sidebar-section.md](../../decisions/0070-contacts-sidebar-section.md) — contacts in the navigation model

## You own

`NextcloudMail/App/**`, `Theme/**`, `Status/**`, `MailSymbol.swift`

## Build

- Your first commit updates [../../product/ux-spec.md](../../product/ux-spec.md) with the
  screens and behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

`AccountEngine` (`NextcloudMail/App/AccountEngine.swift`):

- starts `OutboxSender` per mail account;
- starts `ContactsSync`, `CalendarListSync` and `ServerResultFetcher` once per
  `AccountSession`;
- `SettingsCommands` is created on demand
  ([ADR-0053](../../decisions/0053-settings-builds-its-own-short-lived-coordinators.md)
  pattern).

`NavigationState` gains `enum SidebarSelection: Hashable, Codable` with cases:

- `.mailbox(Int64)`, `.unifiedInbox`, `.priorityInbox`, `.favorites(inboxId: Int64)`,
  `.outbox`;
- `.contacts(sessionId: String, scope: ContactsScope)`, where `ContactsScope` is
  `.all | .favorites | .addressBook(Int64) | .group(String) | .team(String) | .recent`.

Add `ComposeRequest`, verbatim:

```swift
enum ComposeRequest: Codable, Hashable, Sendable {
    case new(accountId: Int64?, mailto: URL?)
    case reply(messageId: Int64, mode: ReplyMode)          // ReplyMode: .sender, .all, .followUp
    case forward(messageIds: [Int64], asAttachment: Bool)
    case editAsNew(messageId: Int64)
    case draft(draftId: Int64)
    case outbox(outboxId: Int64)
    case smartReply(messageId: Int64, text: String)
    case shared(inboxItemId: String)                        // Share extension hand-off
}
```

- Add an environment action `openComposer(_ request: ComposeRequest)` that calls
  `openWindow(id: "composer", value: request)`.
- Start-mailbox restore: the `start-mailbox-id` preference, saved after 5 s in a mailbox.

## Acceptance

- Every engine starts and stops with sign-in and sign-out, including contacts.
- Selection restores across relaunch.

## Out of scope

The engines themselves (WS-21, WS-22, WS-23, WS-24). The sidebar that renders
`SidebarSelection` (WS-28) and its contacts section (WS-35). The composer window that
receives `ComposeRequest` (WS-27) — WS-27 registers `ComposerScene()` itself (standing
exception 2). Project and extension targets (WS-42). Other workstreams may append cases to
`MailSymbol.swift` (standing exception 3); renaming or removing cases stays here.

## Report

Additionally: the start/stop order the engines settled on, and whether sign-out tears down
contacts state cleanly on the first try.
