<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0061: Avatars are fetched into the mirror by a sync worker, through the server's image route only

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** first manual QA pass, after no avatar ever loaded

## Context

The `avatar` table, its reader and `Endpoints.avatar(email:)` all existed. Nothing wrote the
table, so every avatar was coloured initials. The app's loader said as much in a comment.

The server has two routes. `GET /api/avatars/url/{email}` returns `{url, mime, isExternal}`.
`GET /api/avatars/image/{email}` returns the bytes, but only for *external* avatars (Gravatar
and favicons, fetched by the server). For anything else it answers 404, which in practice
means address-book contacts whose vCard `PHOTO` is a URI. The server ignores embedded vCard
photos outright (`ContactsIntegration::getPhotoUri`, "ignore contacts >= 1.0 binary
images"), and embedded is how Nextcloud Contacts stores every photo it saves. So most
contact photos are unreachable through the Mail API at all
([server finding 16](../feedback/server-findings.md)). Getting them takes CardDAV, which is
deferred to the planned Contacts feature. That feature can fill this same `avatar` table, and
the views need no change.

## Decision

- A per-account `AvatarFetcher` actor in `NCMailSync`, started by `AccountEngine` with the
  other workers, writes the `avatar` table:
  - It works through the account's senders newest-correspondent first, 25 per batch, 4
    requests in flight.
  - Each answer is stored as the bytes, or as `missing` on a 404.
  - Photos are asked for again after 30 days, 404s after 7.
  - It pauses offline and in Low Data Mode, and the first transport failure ends a pass.
- Only the image route is used. A contact's URI photo is not fetched.
- The app's loader waits on an observation of the address's row instead of reading it
  once. `NCAsyncImage` shows initials until the row lands, then the photo, and the view
  never makes a request.

## Consequences

- The invariant holds: the network writes `avatar`, views read it, and an avatar shown once
  is there offline.
- External avatars are proxied by the server, so a sender's Gravatar or favicon host never
  sees the reader's address.
- Contacts with URI photos show initials. The web client shows those photos.
- The first pass after sign-in asks about every distinct sender once. On an account with
  thousands of correspondents that is thousands of small requests, spread over several
  minutes at 4 in flight.

## Alternatives considered

**Fetch on demand from the loader.** The first draw would be instant for whoever is on
screen, but it puts a request inside a view, which is the one thing the architecture rules
out. With the observing loader, the visible rows get their photos as soon as the fetcher
reaches them, and the fetcher starts with the newest correspondents.

**Follow `/api/avatars/url` for internal avatars.** The URL is whatever the contact's vCard
says, so it can be on any host. Fetching it means an arbitrary outbound request carrying
nothing the server vouched for. Revisit if the server starts serving internal avatars
through the image route.

## Revisit when

The server serves internal avatars through `/api/avatars/image`, or it supports embedded
vCard photos.
