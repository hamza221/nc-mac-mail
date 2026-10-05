<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0071: Widgets read a snapshot file in the app group, never the database

**Status:** Accepted — confirmed by WS-42 (2026-10-04); the snapshot also carries each item's
local id (for the widget's `ncmail://message/<id>` link), sent date and unread flag, and the
app group is the team-prefixed one of [ADR-0100](0100-app-group-and-extension-targets.md)
**Date:** 2026-10-03
**Decided by:** v2 roadmap, confirmed by WS-42

## Context

v2 adds widgets. A widget runs in its own process, so anything it reads must live in an
app-group container. The mirror is a GRDB database with a WAL; sharing it across
processes means moving it into the group container and accepting multi-process SQLite.

## Decision

Widgets read a snapshot file in the app group, never the database.

- The app writes `widget-snapshot.json`, holding the latest ≤ 7 Important and ≤ 7 Unread
  inbox items, into the app-group container. It writes it after every sync pass that
  changes inbox rows, then calls `WidgetCenter.shared.reloadAllTimelines()`.
- Why: avoids moving the GRDB database and its WAL into a container shared across
  processes.
- Privacy: the snapshot holds subjects and senders. It lives in the sandboxed group
  container (ADR-0006 already accepts envelopes on disk).

## Consequences

- The database and its WAL stay single-process; the widget needs no GRDB, no schema and
  no migrations — it decodes one small JSON file.
- The cost is a second copy of up to 14 envelopes on disk, and a widget that is only as
  fresh as the last sync pass that changed inbox rows.
- Privacy posture is unchanged: subjects and senders in the sandboxed group container are
  within what ADR-0006 already accepts.

## Alternatives considered

**Share the GRDB database through the group container.** Moves the database and its WAL
into a multi-process container, buying cross-process locking and corruption risk for data
the widget barely needs.

**The widget fetches from the server itself.** A second network stack, credentials in a
second process, and a widget that spins offline.

## Revisit when

Widgets need data a 14-item snapshot cannot carry, or the database moves into the group
container for some other reason.
