<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0098: New-mail notifications gate on the inbox's envelope enumeration

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-41

## Context

WS-41 posts a banner for new mail and must never storm on an account's first sync: the
initial mirror inserts every envelope of the inbox, and none of those is "new". The sync
writes rows; the notifier reads them, so "new" has to be decided from the mirror alone.

Three signals were available:

1. `MirrorProgress.isComplete` / `account.mirrorState = complete` — every mailbox enumerated
   *and every body downloaded*. On a large account that is hours, during which genuinely new
   mail would be silent.
2. `message.syncedAt` or `sentAt` newer than some launch time — a message moved into the inbox
   from Archive has an old `sentAt`, and `syncedAt` is rewritten by every re-sync of a page.
3. The inbox's own `mailbox.envelopesComplete` — set by stage 1 when the inbox's envelope
   enumeration reaches the end, and only then.

## Decision

- **Per inbox, the gate is `envelopesComplete`.** Only envelope enumeration inserts rows in
  bulk; body backfill and other mailboxes' enumeration insert nothing into the inbox. When
  the gate opens the notifier reads the inbox's highest local message id as its watermark;
  thereafter every unread, non-draft row with a higher id is new mail. Local ids are
  autoincrement, so a server-side move into the inbox (new `databaseId`, new row) is new and
  a local triage move (the row's `mailboxId` changes, its id does not) is not.
- **A closed gate forgets its watermark.** If the column goes back to false (a re-enumeration
  after a cache reset), nothing notifies until it is true again, and the baseline is re-read.
- **Scans run on `(messageCount, unreadCount)` changes only.** `observeMailboxCounts` also
  moves `bodiesPresent` once per downloaded body; a scan per body would be a full id read per
  body during backfill.
- **More than five new messages in one scan become one "N new messages" banner** for that
  inbox, so a Mac that slept through a day of mail, or an inbox that changed id space, does not
  produce a wall of banners.
- **Suppression is decided before posting**: the main window is key (the app is active and one
  of the windows `MailNotifierHooks` registered is key) and the selection shows that inbox —
  the mailbox itself, Unified inbox or Priority inbox. Suppressed rows are not posted later:
  they were on screen. A banner that is posted is presented even when the app is frontmost.

## Consequences

- A launch's baseline is taken when the notifier's observation first runs, so rows a sync
  inserts in the instant between the engine starting and that read do not notify.
- An inbox that is never mirrored (`envelopesComplete` never true) never notifies.
- A message that arrived already read, and is later marked unread on another device, notifies
  then: it is above the watermark and unread. Rare, and indistinguishable from the mirror.
- Nextcloud notifications (`app == "mail"`) use a different rule: each `(login, id)` is shown
  once, remembered in `UserDefaults` and pruned to what the server still lists. They are never
  deleted on the server after display; the web client only dismisses on an explicit click.
