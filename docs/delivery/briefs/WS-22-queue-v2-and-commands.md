<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-22 — Queue v2 and settings commands

**Wave 2, after WS-16, WS-18. Size: L.**

## Goal

Every offline-capable v2 mutation is a queue kind; every server-validated setting is a
command ([ADR-0068](../../decisions/0068-settings-commands.md)).

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../architecture/offline-queue.md](../../architecture/offline-queue.md)
- [../../decisions/0068-settings-commands.md](../../decisions/0068-settings-commands.md) — the one deliberate exception to "queue every mutation"
- [../../decisions/0033-accounts-have-a-local-identity.md](../../decisions/0033-accounts-have-a-local-identity.md)

## You own

`NCMailSync/Operations/**`, `NCMailSync/Commands/**`

## Build

- Your first commit updates [../../architecture/offline-queue.md](../../architecture/offline-queue.md)
  with the behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

New `MailOperation` / `OperationKind` cases:

- tags: `setTag`, `unsetTag`, `createTag`, `updateTag`, `deleteTag`;
- snooze: `snooze`, `unsnooze`, `snoozeThread`, `unsnoozeThread`;
- mailboxes: `createMailbox`, `renameMailbox`, `moveMailbox`, `deleteMailbox`,
  `setMailboxSubscribed`, `setMailboxSyncInBackground`, `clearMailbox`, `markMailboxRead`;
- settings: `setPreference`, `patchAccount`, `setSignature`, `createAlias`, `updateAlias`,
  `deleteAlias`, `setAliasSignature`;
- text blocks: `createTextBlock`, `updateTextBlock`, `deleteTextBlock`, `shareTextBlock`,
  `unshareTextBlock`;
- quick actions: `createQuickAction`, `updateQuickAction`, `deleteQuickAction`,
  `upsertActionStep`, `deleteActionStep`;
- addresses: `addInternalAddress`, `removeInternalAddress`, `trustDomain`;
- mail actions: `sendMDN`, `unsubscribe`, `saveToFiles`;
- contacts and calendars: `contactPut`, `contactDelete`, `addressBookCreate`,
  `addressBookUpdate`, `addressBookDelete`, `addressBookShare`, `calendarPut`.

Rules that are easy to get wrong:

- Each case has a `before` snapshot for undo and discard, as the existing kinds do.
- Local identity for created rows follows
  [ADR-0033](../../decisions/0033-accounts-have-a-local-identity.md).

`actor SettingsCommands` in `NCMailSync/Commands/`, with
`func run(_ command: SettingsCommand) async -> CommandOutcome`, where `SettingsCommand`
covers:

- `updateMailServer`, `testConnection`, `configureSieve`, `saveSieveScript`, `saveFilters`,
  `saveOutOfOffice`, `followSystemOutOfOffice`;
- `importSMIME(pem:privateKey:)`, `deleteSMIME`, `setAliasCertificate`;
- `delegate`, `revokeDelegation`;
- `createAccount`, `deleteAccount`;
- `repairMailbox`, `startOAuth`.

## Acceptance

- Every kind survives quit and drains on reconnect (fake transport).
- A 422 from `saveSieveScript` comes back as `CommandOutcome.failure` carrying the server's
  message.

## Out of scope

The endpoints the kinds call (WS-16). Store tables and DAOs (WS-18). Sending mail — the
outbox has its own actor (WS-23). The DAV writes your contact kinds trigger are applied by
the contacts sync (WS-24). Creating `SettingsCommands` on demand (WS-25). The settings views
that run the commands (WS-38, WS-39, WS-40).

## Report

Additionally: whether the `before`-snapshot pattern held up across the new kinds, and any
kind that turned out to need server validation and moved to a command.
