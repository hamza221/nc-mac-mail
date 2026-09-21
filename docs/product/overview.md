<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Product overview

*What this app is, who it is for, and where v1 stops.*

## The one-sentence version

A native macOS mail client for Nextcloud that keeps a complete local copy of your mail, so
reading and triage are instant and work with the network off.

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

They are not, in v1, a person who composes long HTML mail with inline images from Files.
That person is well served by the web client, and by v1.1.

## What v1 does

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

## What v1 does not do

Deliberately, and with the reasoning in [ADR-0012](../decisions/0012-read-and-triage-scope.md):

**No composer.** No reply, forward, drafts or outbox. The library's rich-text components
are deferred to v1.1, so a composer today means either plain text or an `NSTextView`
bridge this client would have to write and own. The read path proves the library first.

**No account setup.** Accounts are added in the web client. The setup wizard is a large
surface (autoconfig, OAuth for Google and Microsoft, manual IMAP/SMTP) that teaches us
nothing about the component library.

**No Sieve, filters, out-of-office, quick actions, tags management, snooze, S/MIME,
OpenPGP, itinerary cards, AI features, priority inbox, unified inbox, drag and drop.**
Each is either a compose-path feature, an admin surface, or a second-order convenience.
Tags and priority inbox are the two most likely to be missed; both are read-mostly and
both are cheap to add once the mirror exists.

## What the mirror unlocks later, nearly for free

Worth knowing while making v1 decisions, because it changes what "cheap" means in v1.1:

- **Unified inbox** is a query across `message` with no `mailboxId` filter. The web client
  needs a server-side merge; we need a `WHERE` clause.
- **Search across accounts** is already how the FTS table is built.
- **Offline compose** is the same mutation queue with a different operation kind.
- **Spotlight and Quick Look integration** is a `CSSearchableIndex` fed from the same rows.
- **Thread summaries, itineraries, tags** are all columns the mirror already carries in
  `rawJSON`, waiting for a UI.

## How we will know v1 worked

1. A person with a 40,000-message account can install it, sign in, and be reading mail in
   under thirty seconds — with the backfill still running.
2. Airplane mode changes nothing about reading, searching or triaging; it only delays when
   the server hears about it.
3. `feedback/library-feedback.md` has enough in it that `NextcloudUI` can freeze its API on
   evidence instead of on taste.
