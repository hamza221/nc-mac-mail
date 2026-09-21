<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# User stories and acceptance criteria

*The flows v1 must support, each with criteria an agent can verify. A workstream is not
done because the code compiles; it is done when the stories it claims are demonstrable.*

Stories are grouped by the workstream that owns them — see
[../delivery/workstreams.md](../delivery/workstreams.md).

---

## S-01 Sign in (WS-01)

**As** someone with a Nextcloud account, **I want** to sign in without typing my password
into a third-party app, **so that** I can revoke this client without changing my password.

- Entering a server URL and pressing Continue opens the system browser at the server's
  Login Flow v2 page.
- The URL field accepts `cloud.example.com`, `https://cloud.example.com` and
  `https://cloud.example.com/` and normalises all three.
- While the browser is open the app polls and shows a cancellable "Waiting for the
  browser…" state. It gives up after five minutes with a retry, not a dead end.
- On success the app password is written to the Keychain as an internet-password item
  keyed by host and login name, and the Nextcloud password is never seen by the app.
- In the user's Nextcloud security settings the new app password is named
  **Nextcloud Mail (macOS)**.
- Quitting and relaunching does not ask for credentials again.
- Signing out offers "keep local copies" or "remove local copies", and removing wipes both
  the Keychain item and the database file.
- A server that is unreachable, is not a Nextcloud instance, or has no Mail app installed
  produces three distinguishable messages, not one generic failure.

## S-02 First launch fills the mirror (WS-04)

**As** a new user with a large mailbox, **I want** the app usable immediately and complete
eventually, **so that** I am not staring at a progress bar.

- Within seconds of sign-in the sidebar lists accounts and mailboxes.
- The first page of the inbox is on screen before the mirror is anywhere near complete.
- A progress indicator states what is happening in counts, not percentages of an unknown
  total: "Downloading messages — 12,431 of 48,902".
- Quitting mid-backfill and relaunching resumes from where it stopped; it does not restart
  and does not re-download a mailbox it had finished.
- Pulling the network cable pauses the backfill and does not produce an error cascade.
  Reconnecting resumes it.
- Opening a message whose body has not been backfilled yet fetches that one body ahead of
  the queue and shows it; the queue continues afterwards.
- Backfill pauses on Low Power Mode and on an expensive or constrained network, and says
  so where the progress is shown.
- Only subscribed mailboxes are mirrored ([ADR-0007](../decisions/0007-subscribed-mailboxes-only.md)).
  Unsubscribed ones still appear and still open; they fill on demand.

## S-03 Read the inbox (WS-08, WS-09)

**As** someone processing mail, **I want** the list and the message to appear instantly.

- Selecting a mailbox renders its first screen of rows in under 100 ms on a mirrored
  mailbox, measured from selection to first frame, with no network involved.
- Scrolling is smooth through tens of thousands of rows; the list is windowed over the
  database, never an in-memory array of everything.
- Unread rows are semibold; the mailbox shows an unread count that matches the server's.
- Threaded view shows one row per thread with a message count; flat view shows every
  message. Switching is instant and is remembered.
- A message shows subject, sender with avatar, recipients, date, attachment list and body.
- Remote images do not load until the reader asks, and asking can be remembered for that
  sender.
- A thread shows its siblings, collapsed, with the selected message expanded.
- With the network off, every message that has been backfilled opens normally. One that
  has not says so plainly and offers to fetch it when a connection returns.

## S-04 Search (WS-11)

**As** someone looking for a message from eight months ago, **I want** to find it by any
word in it.

- Typing in the search field returns results as you type, from the local index, with no
  network request.
- Search covers subject, preview, body text, sender and recipient names and addresses.
- Results are scoped to the current mailbox by default with a control to search all
  mirrored mailboxes, across accounts.
- Matching terms are highlighted in the result rows (`NCHighlightText`).
- Search works with the network off, and on an account whose body backfill is incomplete
  it says how much of it has been indexed so far rather than silently under-reporting.

## S-05 Triage (WS-10)

**As** someone clearing an inbox, **I want** one keystroke per decision.

- `A` archive, `S` star, `U` toggle unread, `Delete` delete, `J` junk, `R` refresh,
  `↑`/`↓` move selection, `⌘F` search, `⇧` extends selection.
- Every action updates the list immediately — before the server is contacted.
- Selecting several messages and acting applies to all of them as one batch.
- Acting on a thread acts on every message in it.
- Archive uses the account's `archiveMailboxId`; junk sets `$junk` and moves to
  `junkMailboxId`; delete moves to trash, or erases when already in trash.
- An action whose request fails is rolled back visibly, with a message naming what failed
  and a retry — never a silent revert.
- Done offline, every one of these actions sticks, and reaches the server on reconnect
  ([S-06](#s-06-work-offline-ws-06)).

## S-06 Work offline (WS-06)

**As** someone on a train, **I want** the app to behave as though nothing is wrong.

- With the network off the app opens, lists, reads, searches and triages with no error
  banners. A single unobtrusive "Offline" indication is enough.
- Actions taken offline survive a quit and a relaunch.
- On reconnect, queued actions drain in order, and the indicator shows the count going
  down.
- An action that the server rejects because the message moved or vanished elsewhere is
  dropped quietly and the local copy reconciled; an action that fails for any other reason
  is retried with backoff and, after repeated failure, surfaced once with a retry control.
- Two conflicting changes — starred here, unstarred in the web client — resolve to the
  local intent for the field the action set, and to the server for everything else, with
  the rule written down in [../architecture/offline-queue.md](../architecture/offline-queue.md).

## S-07 Stay in sync (WS-05)

**As** someone with the app open all day, **I want** new mail to appear without asking.

- New mail appears within the sync interval (default two minutes on the foreground
  mailbox, ten minutes elsewhere) and immediately on `R` or on window focus.
- A message read, starred, moved or deleted in the web client is reflected here on the
  next sync.
- A mailbox the server has not cached yet is primed automatically; the user never sees a
  428 or a 202.
- Sync failure on one mailbox does not stop the others and does not clear what is already
  mirrored.
- A deep reconciliation runs weekly per account, and on demand, catching anything the
  incremental path structurally cannot see — the cases are enumerated in
  [../architecture/sync-engine.md](../architecture/sync-engine.md).

## S-08 Manage storage (WS-12)

**As** someone with a 60 GB mailbox and a 256 GB laptop, **I want** to know and control
what this app is keeping.

- Settings › Storage lists each account with its local size, message count and mirror
  state.
- "Remove local copies" deletes bodies and attachments for that account, keeps envelopes,
  and the app keeps working — bodies re-fetch on open.
- "Re-download" clears and restarts the backfill.
- Pausing the backfill is one control and it persists across launches.
- The app never deletes mail from the server as part of any storage operation, and the
  confirmation says so in those words.

## S-09 It looks like the instance it belongs to (WS-13)

**As** a user of a themed Nextcloud, **I want** the app to match it.

- On launch the app reads `/ocs/v2.php/cloud/capabilities` and applies
  `theming.color` through `NCBrand` and `NCTheme`.
- Changing the colour server-side and relaunching recolours the app.
- The brand colour drives selection and focus, not just avatars.
- Light and dark both work, and the message body follows suit without mangling HTML mail
  that assumes a light background ([../architecture/rendering.md](../architecture/rendering.md)).
- Sidebar icons are Material Design glyphs, not SF Symbols fallbacks — which is only true
  when built by Xcode ([ADR-0001](../decisions/0001-xcode-project-in-git.md)).

## S-10 Several accounts (WS-07)

- Each account is a section in the sidebar with its own mailbox tree, in the server's
  `order`.
- Each account mirrors and syncs independently; one broken account does not block another.
- Actions always resolve special mailboxes against the account that owns the message, not
  the selected account.
