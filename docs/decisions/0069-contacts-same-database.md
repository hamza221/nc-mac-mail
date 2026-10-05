<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0069: Contacts use the same database and the same five modules, keyed by Nextcloud login

**Status:** Accepted
**Date:** 2026-10-03 (accepted 2026-10-04)
**Decided by:** v2 roadmap; placement and lossless vCard confirmed by WS-17/WS-18, the sync
protocol confirmed by WS-24 against the live server

## Context

v2 adds Nextcloud Contacts parity (ADR-0064). Contacts arrive over CardDAV, not the mail
API, and belong to a Nextcloud login rather than a mail account — one login has many mail
accounts and one set of address books. The module layout (ADR-0013, grown since) and
AGENTS.md's "No network call outside NCMailNet" constrain where the new code can live.

## Decision

Contacts use the same database and the same five modules, keyed by Nextcloud login.

- Placement: the DAV client goes in `NCMailNet/DAV`; vCard and iCalendar value types in
  `NCMailCore/Contacts` and `NCMailCore/Calendar`; tables in `NCMailStore`; sync in
  `NCMailSync/Contacts`; UI in `NextcloudMail/Views/Contacts`.
- No new package: "No network call outside NCMailNet" (AGENTS.md) forbids a self-contained
  contacts package with its own networking, and one database lets autocomplete join
  contacts against mail addresses.
- Keying: contacts belong to an `AccountSession` (server and login,
  `NextcloudMail/App/AccountSession.swift`), not to a mail `account` row, because one
  Nextcloud login has many mail accounts and one set of address books.
- vCard handling: our own lossless vCard 3.0/4.0 parser and serialiser that preserves
  unknown properties and parameters. Not `CNContactVCardSerialization`, which drops `X-`
  properties and loses data on round trip.
- Sync protocol: RFC 6578 `sync-collection` with sync tokens. Writes use `If-Match`. On
  412, refetch and reapply the locally edited properties
  ([ADR-0082](0082-contact-writes-reapply-per-property.md) fixes the unit, the winner and the
  retry count).

## Validation (WS-24)

Measured against Nextcloud with Contacts 8.10, recorded in `docs/architecture/sync-engine.md`:

- `sync-collection` + `addressbook-multiget` in batches of 100 mirrors a 2,000-card book well
  inside the 60-second budget (the number is in the WS-24 report and the sync-engine doc).
- Two server behaviours the plan did not foresee, both handled without leaving the protocol:
  a book listed **without** a `sync-token` ("Recently contacted") refuses `sync-collection`
  with 415, so it is mirrored from an ETag listing; and a refused token is a 403
  `InvalidSyncToken`, answered with a full resync.
- The address book on/off toggle is server state (`oc:enabled`), not local preference.

## Consequences

- Autocomplete can join contacts against mirrored mail addresses in one SQL query, and
  contacts get the mirror's properties for free: offline reads, observation, one backup
  story.
- Round trips through other CardDAV clients lose nothing, because unknown properties and
  parameters survive our parser.
- The cost is a vCard parser and serialiser of our own, and five modules that each grow a
  contacts-shaped wing rather than one new package with a single owner.

## Alternatives considered

**A self-contained contacts package with its own networking.** Forbidden by "No network
call outside NCMailNet", and a second database would put a process boundary where
autocomplete wants a join.

**`CNContactVCardSerialization`.** Drops `X-` properties and loses data on round trip; a
sync client cannot be lossy.

**Keying contacts to the mail `account` row.** One login has many mail accounts and one
set of address books; the contacts would be duplicated or orphaned.

## Revisit when

Contacts outgrow the mail database (size or schema churn), or a shared Nextcloud CardDAV
package appears worth depending on.

Nextcloud gives "Recently contacted" a sync token, or the store grows past what one
multiget per 100 cards can fill in a minute.
