<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0096: Address-book management, vCard import and merge are queued card writes

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-36

## Context

WS-36 builds the rest of web Contacts: address-book create/rename/enable/share/delete, vCard
import and export, merging two contacts, batch delete, and the Contacts settings. The queue
already had every DAV kind needed (`addressBookCreate/Update/Delete/Share`, `contactPut`,
`contactDelete`, `contactSocialAvatar`). Several choices came up that a reviewer could
reasonably have made differently.

## Decision

1. **Import is one `contactPut` per card, through the normal queue.** No batch kind. A
   vCard import is N PUTs on the wire whatever the queue does (CardDAV has no bulk write),
   and a row per card keeps Discard, 412 handling and conflicts per contact. Measured: 500
   cards queue in about half a second offline (120 in 0.13 s in the unit test); the live
   drain time is in the WS-36 report and parity row C7.
2. **A UID already in the target book updates that contact**, so importing an export back
   into its book changes nothing instead of making a duplicate. A card with no UID, or one that
   repeats a UID seen earlier in the same file, gets a fresh one. A new card goes to
   `<book>/<UID>.vcf` like web Contacts, unless the UID is not a safe file name (`urn:uuid:…`):
   then the file name is a fresh UUID and the UID stays as written.
3. **Export is written from the mirror**, not fetched with `?export`, so it works offline. Every
   card goes through `VCardSerializer`, which writes each untouched line exactly as stored. Only
   the line folding may differ from the server's own export (`VCardExchangeTests.exportKeepsEveryLineAsStoredModuloFolding`).
4. **Merge keeps one card and deletes the other**: one `contactPut` over the kept card and one
   `contactDelete`, in that order. The plan models eleven single-value properties (each one the
   cards disagree on gets a radio button; the kept card's value is the default, and an empty
   field on the kept card is filled from the other) and seven multi-value ones (a checkbox per
   line, every line ticked by default, duplicates folded by normalised value). `CATEGORIES`
   are combined by default. Everything else on the kept card stays as written, in place. Lines
   brought over from the other card keep their `itemN.` companion (an Apple `X-ABLabel`); if
   the kept card already uses that group, the companion is renamed.
5. **Shared books are the owner's to change.** Rename, share and delete are offered only on
   the login's own books; enable/disable is offered on every book, because `oc:enabled` is
   stored per user.
6. **Social-avatar auto-update is a per-Mac switch that works when a contact is viewed.** Web
   Contacts' switch turns on a server background job through
   `PUT /apps/contacts/api/v1/social/config/user/enableSocialSync`. This app has no client for
   that route, and NCMailNet belongs to another workstream. So when the switch is on, viewing a
   contact in a writable book queues a `contactSocialAvatar` for the first network the card
   supports, at most once a day per UID. The sort order stays the per-Mac
   `contacts.orderKey` WS-35 introduced.

## Consequences

- An import done offline behaves the same as one done online: the cards are in the list at
  once, and the queue sends them in order once the Mac is online.
- Merge does not cover: the other card's unmodelled properties (dropped), its favourite
  flag (a DAV property, not vCard), and `KIND:group` cards that list it as a `MEMBER` (they
  keep a dangling member). Each would add writes beyond one put and one delete. They are
  listed in the WS-36 report.
- Existing shares of a book are not listed and cannot be removed. That needs a share-listing
  property in the mirror and a `CS:remove` share body in `DAVClient`, neither of which exists
  yet.
- The social switch does not follow the user to the browser, and the server's own job is not
  turned on.
