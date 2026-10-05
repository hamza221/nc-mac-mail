<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0093: A calendar write whose UID the calendar already holds updates the server's copy

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-34

## Context

The iMIP card answers an invitation by writing the event, with the user's PARTSTAT, into a
calendar through the queued `calendarPut` (the brief: "the server's scheduling sends the
reply — confirm on the live server"). The web client first runs a `calendar-query` by UID
over every writable calendar and updates the copy it finds; a view here may not fetch, and
the mirror lists calendars without their objects (ADR-0069).

Measured on the dev server (Nextcloud with Sabre VObject 4.5.6), by curl and then end to
end through the queue in `CalendarLiveTests`:

- A same-server organiser's invitation is **already in the attendee's calendar** before any
  mail is read: scheduling delivers it into the schedule-default calendar as
  `sabredav-<uuid>.ics`, PARTSTAT=NEEDS-ACTION.
- A PUT of a second object with that UID into the **same calendar** answers **409**, with
  the existing object named in the CalDAV `no-uid-conflict` precondition (RFC 4791
  §5.3.2.1) — recorded as `dav-error-uid-conflict-ws34.xml`:
  `<cal:no-uid-conflict><d:href>…/ws34-first.ics</d:href></cal:no-uid-conflict>` beside
  `OCA\DAV\Exception\UidConflict`.
- A PUT into **another calendar** is accepted (201): the UID check is per calendar.
- **Sabre schedules before the UID check.** The refused PUT still sends the organiser a
  REPLY and flips their copy (a deliberate TENTATIVE probe through a 409 moved the
  organiser's PARTSTAT to TENTATIVE). Only the attendee's own copy is left unchanged.
- Updating the existing copy (PUT at its href, no `If-Match`) sends the REPLY again and
  changes the attendee's copy. The REPLY carries PARTSTAT and CN only: the comment
  (`X-RESPONSE-COMMENT` and COMMENT, which the web writes too) stays on the attendee's copy.
- An object with a `METHOD` property is refused with 415 ("A calendar object on a CalDAV
  server MUST NOT have a METHOD property"), so the attached iMIP copy loses METHOD first.

How the live run is seeded (`CalendarLiveTests`), since outgoing SMTP answers 452 on the dev
server and the attendee's principal address (`admin@example.net`) is not the mail account's
address: `alice` PUTs an event inviting `admin@example.net` into her personal calendar;
the same object with `METHOD:REQUEST` goes into a `text/calendar; method=REQUEST` part of a
mail APPENDed to the account's INBOX through the server's own IMAP client (`docker exec … php`
with `IMAPClientFactory::getClient($account)->append(…)`, as `Scripts/record-fixtures.sh`'s
WS-34 section does); `admin@example.net` is added as an alias so the card recognises the
attendee; a flight confirmation with schema.org JSON-LD is APPENDed the same way for the
itinerary extractor, which answered it with one `FlightReservation`.

## Decision

- `DAVErrorBodyParser` reads the `no-uid-conflict` href; a 409 carrying it becomes
  `DAVError.uidConflict(href:)`. A 409 without it stays `collectionConflict`.
- `ContactWriteHandler.send` for `calendarPut`: on `uidConflict`, PUT the same body **once**
  more at the server's href, without `If-Match`. A second 409 throws, and the drainer parks
  the row as a conflict, like a 412 (`OperationDrainer.mailError(for:)`).
- The iMIP card writes into the schedule-default calendar unless the user picks another
  ("Save to"); with the account's `imipCreate` on, there is no choice, because the server
  creates the event in that calendar itself.

The same rule makes importing an itinerary twice idempotent: its UID is
`md5(messageId + …)` as on the web, so the second import updates the first.

## Consequences

- Accepting a same-server invitation reaches the organiser with one queued row and no
  read: measured live, the answer drained in 0.57 s (409, then 204 on the server's copy),
  the attendee kept one copy, the organiser's copy read ACCEPTED, and the organiser's
  schedule inbox held two identical ACCEPTED REPLY objects — one per PUT.
- The re-PUT overwrites the server's copy with the message's copy. If the organiser changed
  the event after sending this invitation and scheduling already updated the attendee's
  copy, answering an **older** invitation mail writes the older details back. The web
  avoids this by editing the copy it fetched; the next pass of a calendar-object mirror is
  where this would be fixed.
- Picking a calendar other than the one scheduling delivered to leaves two copies (the
  server's NEEDS-ACTION one and the answered one). The organiser still gets the REPLY.
- A reopened card cannot know the server's PARTSTAT without the objects: it shows an
  answer still waiting in the queue, and otherwise the buttons again.

## Alternatives considered

**A `calendar-query` by UID before writing**, as the web does. It needs either a fetch from
the view or a new `serverResult` kind, and is still racy against scheduling's own delivery.
The 409 already names the object, in the one round trip the write makes anyway.

**Re-target with the server's ETag.** The 409 body carries no ETag, and a precondition on a
copy only scheduling writes adds a failure mode without protecting a user edit.

## Revisit when

The calendar mirror carries objects (a WS-24 successor): the card can then read the server's
copy by UID, show "You accepted" from it, and write onto it directly.
