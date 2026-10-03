<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Product overview

*What this app is, who it is for, and what v2 adds.*

## The one-sentence version

A native macOS mail and contacts client for Nextcloud that keeps a complete local copy of
your mail and address books, so everything is instant and works with the network off.

## Why it exists

Two reasons, and they pull in the same direction.

**For Nextcloud users.** The Mail web client is good and improving, but it is a browser
tab. It has no Spotlight-grade search of your own mail, it cannot show you anything on a
plane, and it competes with forty other tabs for a window. Nextcloud ships a native
desktop client for Files. Mail does not have one.

**For `NextcloudUI`.** The package has six waves of components and a README that says the
next step is to build a real Mail client against it and freeze the API on what that finds.
A showcase demo inside the package proves less than a client built from outside it. This
app is that test, and [feedback/library-feedback.md](../feedback/library-feedback.md) is
its second deliverable — arguably the more valuable one.

## Who it is for

The Nextcloud user who lives in mail: forty to four hundred messages a day, several
mailboxes, and a habit of processing the inbox down to nothing. That person cares about,
in order: how fast the list responds, how few keystrokes a triage pass takes, and whether
their mail is readable when the connection is not.

In v2 they are also the person who writes mail: replies, forwards, rich text, attachments
from Files, scheduled sends. The composer is no longer the web client's job.

## What v1 shipped

**Sign in.** Login Flow v2 in the browser, an app password in the Keychain, no Nextcloud
password ever stored. Multiple accounts.

**Mirror.** On first login, every subscribed mailbox is downloaded: envelopes first, so
the app is usable within seconds, then every message body behind that, newest first. The
mirror is complete, resumable across quits and reconnects, and never silently evicts.
Progress is visible and pausable. See [ADR-0003](../decisions/0003-local-first-full-mirror.md).

**Read.** Sidebar of accounts and mailboxes, threaded or flat message list, message view
with header, body, attachments and thread siblings. Remote content is blocked until you
say otherwise, per sender. Everything renders from the local database, at local-database
speed, whether or not the server is reachable.

**Search.** Full-text, local, instant, across subject, sender, recipients, preview and
body, in every mirrored mailbox at once. This is the capability the mirror unlocks that
the web client cannot match — server-side IMAP body search is slow enough that Nextcloud
Mail hides it behind a per-account opt-in.

**Triage.** Read, unread, star, important, archive, delete, junk, move. Single messages or
whole threads, from the toolbar, a context menu or the keyboard. Actions apply to the
local copy immediately and are replayed to the server, including actions taken while
offline. See [ADR-0005](../decisions/0005-offline-mutation-queue.md).

**Manage storage.** Settings shows what the mirror is using, per account, and offers
"remove local copies" and "re-download". No automatic eviction: a mirror that quietly
drops your mail is not a mirror.

## What v2 adds

**Compose.** A full composer: reply, forward, rich text in an editor this app owns,
attachments from disk and from Files, drafts synced to the server, a send undo window, and
scheduled sends through the server outbox. Row by row in [parity.md](parity.md).

**Mail parity.** Everything else the web client's mail surface does: account setup, aliases
and signatures, tags, snooze, filters and Sieve, out-of-office, unified and priority
inboxes, drag and drop, S/MIME. The complete mapping is [parity.md](parity.md).

**Contacts.** Nextcloud Contacts parity: address books mirrored over CardDAV into the same
local database, browsed from a Contacts section in the sidebar, edited offline through the
same queue. Scope per row in [parity.md](parity.md).

**Calendar from mail.** The mail-side calendar surfaces: iMIP invitation replies, itinerary
cards, "add to calendar" from event data in messages. Listed in [parity.md](parity.md).

**Configuration.** App settings and account settings — text blocks, trusted senders,
internal addresses, autoresponder, provisioning — validated online where the server must
have the last word. Each setting has a row in [parity.md](parity.md).

**On the Mac.** The native integrations a browser tab cannot offer: Spotlight, widgets, a
share extension, Services, `mailto:` handling, notifications. Mapped in
[parity.md](parity.md).

## What v2 does not do

Deliberately, with the reasoning in [ADR-0064](../decisions/0064-v2-parity-scope.md):

- **Admin settings (§9):** a server-administration surface the web admin panel already
  serves.
- **PGP/Mailvelope:** a browser extension with no native equivalent chosen. The app shows
  an honest notice on PGP mail instead.
- **Debug-only items:** "Clear cache", "Report this bug", "Download thread data for
  debugging".
- **Browser mechanics with native replacements**, mapped in [parity.md](parity.md):
  history back/forward, Ctrl+click new tab, responsive breakpoints, beforeunload.
- **Server-only behaviour with no client surface:** OCP Mail Provider, junk/ham reports,
  user migration, AI listeners.

## What the mirror unlocks later, nearly for free

Worth knowing while making v1 decisions, because it changes what "cheap" means in v1.1:

- **Unified inbox** is a query across `message` with no `mailboxId` filter. The web client
  needs a server-side merge; we need a `WHERE` clause.
- **Search across accounts** is already how the FTS table is built.
- **Offline compose** is the same mutation queue with a different operation kind.
- **Spotlight and Quick Look integration** is a `CSSearchableIndex` fed from the same rows.
- **Contacts** are the same mirror, the same queue.
- **Thread summaries, itineraries, tags** are all columns the mirror already carries in
  `rawJSON`, waiting for a UI.

## How we will know v1 worked

1. A person with a 40,000-message account can install it, sign in, and be reading mail in
   under thirty seconds — with the backfill still running.
2. Airplane mode changes nothing about reading, searching or triaging; it only delays when
   the server hears about it.
3. `feedback/library-feedback.md` has enough in it that `NextcloudUI` can freeze its API on
   evidence instead of on taste.
