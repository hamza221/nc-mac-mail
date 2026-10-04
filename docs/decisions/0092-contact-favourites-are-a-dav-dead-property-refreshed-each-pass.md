<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0092: Contact favourites are a DAV dead property, refreshed by a listing each pass

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-35

## Context

The brief asked which vCard property web Contacts uses for its favourite star. Read from
the shipped bundle (`contacts-main.mjs`, cdav-library's `_exposeProperty("favorite",
NEXTCLOUD)`) and measured against the dev server with a scratch book:

- The favourite is **not in the vCard**. It is the WebDAV dead property
  `{http://nextcloud.com/ns}favorite` on the card resource — `.com`, not the
  `http://nextcloud.org/ns` every other Nextcloud property uses. Set: PROPPATCH
  `<nc:favorite>1</nc:favorite>`; unset: PROPPATCH `<d:remove>`. An unset card answers a
  PROPFIND for it with a 404 propstat.
- The PROPPATCH moves **neither the card's ETag nor the book's sync-token** (PROPFIND of both
  before and after, by curl first and then in `ContactsLiveTests.favouriteRoundTripsBothWays`).
  `sync-collection` therefore never reports a favourite toggled in the browser.

The mirror (ADR-0069) syncs books by `sync-collection` and skips a book whose token did not
move, so without a change a star set elsewhere never reaches the Mac.

## Decision

- `nc:favorite` is asked for alongside `address-data` in every `addressbook-multiget`, so a
  card fetched in a round arrives with its flag.
- Every pass, each token book also gets one Depth-1 PROPFIND for `{getetag, nc:favorite}`,
  **even when its token did not move**. The answer is applied whole to the book
  (`MailStore.syncContactFavorites`): exactly the listed `"1"` hrefs are favourites. Token-less
  books (Recently contacted) already list by ETag each pass; the same listing carries the flag.
- A toggle is a queued `contactFavorite` (`DAVWritePayload.enabled`, `before.isFavorite`): the
  row flips locally at once, the drainer PROPPATCHes, Discard restores `before.isFavorite`.
  Cards a queued favourite or content write owns keep their local flag against the listing.

## Consequences

- One extra request per enabled token book per pass. Measured live
  (`ContactsLiveTests.favouriteRoundTripsBothWays`): the pass that mirrored an unstar made
  3 favourite listings for the dev account's 4 enabled books (Recently contacted lists by
  ETag anyway) and took 1.30 s end to end. The listing is about 300 bytes per card (the
  recorded 2-card answer is 1,163 bytes), so a 2,000-card book costs roughly 600 KB a pass.
- A toggle elsewhere shows within one contacts pass, like any other change.
- The favourite survives a vCard PUT untouched — it is a property of the resource, not the
  data (measured with curl: PROPPATCH, PUT new data, PROPFIND still answers `1`) — which is
  why web Contacts and this app can both edit the card freely.

## Alternatives considered

**`CATEGORIES` containing a "Favorites" value.** What the brief guessed; not what web
Contacts does, so stars would not round-trip with the browser.

**Only read `nc:favorite` in the multiget.** Sees a toggle only when something else changed
the card; a star set in the browser would wait indefinitely.

**PROPFIND only when the token moved.** Same flaw: the toggle does not move the token.

## Revisit when

The Contacts app moves the favourite into the vCard, or the server starts bumping the
sync-token on dead-property changes — then the per-pass listing becomes redundant.
