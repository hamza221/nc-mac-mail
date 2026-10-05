<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0091: App settings: switches span every login, server lists follow a picked login, gated tabs stay

**Status:** Accepted — extends 0088
**Date:** 2026-10-04
**Decided by:** WS-38

## Context

The web client's app settings (`AppSettingsMenu.vue`, checklist §7) belong to one Nextcloud
user on one server. This app signs in to several logins at once and has one Settings window.
Two kinds of thing live in §7:

- **Switches and pickers** (`collect-data`, `external-avatars`, `auto-mark-as-read`,
  `reply-mode`, `internal-addresses`, `follow-up-reminders`, `index-context-chat`,
  `layout-message-view`, and the list preferences ADR-0088 already settled): one value per
  login on the server, but the user means one value for this app.
- **Lists** (trusted senders, internal addresses, text blocks and their shares, S/MIME
  certificates): different content per server. Merging them would make "Remove" ambiguous —
  the same domain trusted on two servers is two rows — and a text block shared on one server
  cannot be shared with users of another.

Some tabs depend on what a server offers (`llmFollowupAvailable`, `contextChatAvailable`).

## Decision

- Switches read the **first login** (lowest id) and write **every login** through the queue's
  `setPreference`, reusing `MessageListPreferenceStore.write` — ADR-0088's rule, extended to
  all of §7. A login already holding the value is skipped.
- Lists act on **one picked login**: a "Nextcloud account" picker above each list, shown only
  when more than one login is signed in, defaulting to the first. Writes are queued
  operations (or ADR-0068 commands for S/MIME) against that login.
- A feature-gated tab **stays in the tab bar**: its control is disabled with a line saying the
  server does not offer it. A Settings tab that appears and vanishes as flags are
  rediscovered reads as a bug. A nil flag (not yet discovered) counts as available.
- PKCS #12 is converted on this Mac (`SecPKCS12Import` with `kSecImportToMemoryOnly`, so
  nothing lands in the login keychain); only the PEM certificate and key are uploaded. The
  password is a function argument and nothing else.

## Consequences

- Switching a preference with two logins queues two operations; offline, both drain later.
- Someone who wants different values per server must use the web client for the second one.
- `AppSettingsModel` keeps two observation scopes (first login, selected login) instead of one.
