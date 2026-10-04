<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0088: The list's layout preferences are read from the first login and written to every login, and the selection lives in the list model

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-29

## Context

The web client keeps `layout-mode`, `compact-mode`, `sort-order`, `sort-favorites` and
`follow-up-reminders` as per-user server preferences. This app has one window and can be
signed in to several Nextcloud logins at once, each with its own values, mirrored into
`preference` rows by `ServerStateMirror`. The brief requires the sort order to be written to the
server rather than kept locally, and the window can change shape (three columns, two columns
with a vertical split, list only) while a message is selected.

## Decision

1. **Read from the first login** — the lowest local `login.id`, which is stable across
   launches. One window has one layout; picking "the selected mailbox's login" would make the
   window change shape whenever the user crossed accounts.
2. **Write to every login** through the queue's `setPreference` kind
   (`MessageListPreferenceStore.write`), skipping a login that already holds the value, as
   `saveStartMailbox` does for Unified/Priority. The queue applies the row locally in the same
   transaction, so the change is visible at once and offline; the server catches up when the
   drainer runs. Sort order therefore reaches each server, whose `GET /messages` cursor follows
   it on the next sync run (ADR-0036).
3. **The selection lives in `MessageListStore`**, owned by the shell for the life of the
   window, and the list views attach/detach by count. A layout change swaps views — possibly
   showing the new one before removing the old — so the model stops its observations only when
   the last view has gone and resumes, selection intact, when one comes back.

## Consequences

- With two logins whose web settings differ, this app first shows the first login's, and the
  first change it makes brings them into line.
- A view-local selection (`@State`) was rejected: it is lost on every layout switch.
- WS-38's settings UI writes through the same `MessageListPreferenceStore`.
