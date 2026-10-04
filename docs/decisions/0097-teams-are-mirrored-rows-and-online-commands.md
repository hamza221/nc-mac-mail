<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0097: Teams are mirrored rows behind a capability gate, and team edits are online-only commands

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-37

## Context

WS-37 brings web Contacts' Teams (the Circles app), "Shared items" and the organisation chart.
Teams exist only when the server runs Circles; the roadmap's rule is that on a server without
it the surfaces never appear. Team data is computed by the server (ADR-0067 lists "Teams
lists"), and the `team` / `teamMember` tables already exist. Team edits — create, add a
member, change a level, change options — are checked by Circles against rules a client cannot
see (a `ROOT` team refuses to join another team, an existing member cannot be added twice,
the last owner cannot leave).

The routes, confirmed live on Nextcloud 36 (all under `/ocs/v2.php/apps/circles/`):
`GET circles`, `POST circles {name, personal, local}`, `PUT circles/{id}/{name|description|config}
{value}`, `DELETE circles/{id}`, `GET circles/{id}/members`, `POST circles/{id}/members
{userId, type}`, `PUT circles/{id}/members/{memberId}/level {level}`, `PUT
circles/{id}/members/{memberId}` (accept a join request), `DELETE circles/{id}/members/{memberId}`,
`PUT circles/{id}/leave`. They match what web Contacts calls (`src/services/circles.ts`).

## Decision

- **One `serverResult` row is both the gate and the refresh.** `ServerResultKind.teams`
  (key `all`) reads `GET /ocs/v2.php/cloud/capabilities` first. With no `circles` entry it
  empties `team` and answers `empty`; with one it replaces `team` and `teamMember` from the
  list and each team's members (fetched concurrently) and answers `{"count"}`. The views show
  Teams only while that row is `ready` — no row, `empty` and a first failure all hide them. A
  later failure keeps the earlier `ready` row and the mirrored teams (ADR-0067's rule).
- **Absence is read from the capabilities, not from a 404.** The capability is what the
  server says about itself; a failing Circles route on a server that has the app is a failure,
  not a reason to hide the user's teams.
- **Team edits are online-only commands** in ADR-0068's shape: `ServerResultFetcher.run(_:
  TeamCommand)` sends the request, and on success re-runs the `teams` fetch before returning
  `CommandOutcome`, so the view that awaited the outcome already sees the change in the
  store. Nothing is queued; offline the edit fails at once with the transport error.
- **`teamMember.userId` holds `"<source>:<id>"`** (`basedOn.source`, then the user id, group
  id, address or team name): a user and a group named alike can both be members of one team,
  and the server reports a group member as `userType` 16, so `basedOn.source` is the kind
  that means what the person added. The Circles member id that the edit routes take stays in
  `rawJSON`.
- **Shared items** is `ServerResultKind.sharedItems` (key: the user id), for system-address-book
  cards only (whose UID is the user id). It filters the two files_sharing listings (`shares`
  and `shares?shared_with_me=true`) down to user shares between the login and that user, newest
  first. Web Contacts gets these panels from the `related_resources` app (Files, Talk,
  Calendar, Deck); that app is not part of a default install, and is absent on the test server,
  where the web panels hide themselves. Files shares are what every server has.
- **The organisation chart is computed in the app from the mirror** (`OrgChart`, pure): the
  manager is web Contacts' `X-MANAGERSNAME;UID=` — what the server writes into the system
  address book from the profile's Manager field, verified live — looked up in the card's own
  book. A missing manager makes its report a top of a chart; a cycle is cut at its
  alphabetically first member. The chart renders as indented levels.

## Consequences

- On a server without Circles nothing about Teams is drawn and no Circles route is called
  (`TeamsFetcherTests.noCirclesHidesEverything`, `TeamsListingTests.nothingShowsWithoutAReadyTeamsRow`).
- Teams cannot be edited offline; the cached list stays readable.
- Local `team.id`s change on every refresh (the table is replaced); anything that must survive
  a refresh — the sidebar selection — keys on the remote id.
- Shared items lists Files only, not the Talk, Calendar and Deck panels `related_resources`
  adds where it is installed.

## Alternatives considered

**Queue team edits as mutation kinds.** A refused replay (a member who already joined
elsewhere, a `ROOT` team) would fail hours later with nobody looking, and a created team's
id is needed before members can be added to it.

**Detect Circles by calling `GET …/circles` and treating 404/998 as absent.** Conflates "app
missing" with "route failing", and would hide a user's teams on a transient server error.

**Use `related_resources` for Shared items.** Absent on a default server; a route that does
not exist answers OCS 998. Can be added beside the files listing where a server has it.

## Revisit when

Circles gains an OCS endpoint that returns teams with their members in one call, or
`related_resources` ships with the server.
