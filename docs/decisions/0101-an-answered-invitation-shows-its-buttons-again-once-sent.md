<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0101: An answered invitation shows Accept/Decline again once the queue drains

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-44's parity audit (defect D-3 against WS-34), on the code as built:
`MessageCalendarModel.answers` and `CalendarActions.pendingAnswer`

## Context

The web client's iMIP card (`Imip.vue`) decides "You already reacted to this invitation"
from the event in the user's calendar: it looks the invitation's UID up over CalDAV and
reads the user's PARTSTAT off that copy. The answer lives on the server's calendar object,
so it survives a reload, another device, and the web answering it.

This app mirrors calendars, not calendar objects. The login's `calendar` rows carry name,
colour, components and writability (ADR-0093 is the write side); no `VEVENT` the user owns is
in the database. So the card has two places to find an answer
(ux-spec.md, "Calendar in the message view (WS-34)"):

1. The attached copy itself, when its own ATTENDEE line already carries a PARTSTAT other than
   NEEDS-ACTION. Organisers rarely send one like that.
2. The queue: an answer given here is a `calendarPut` operation until the drainer sends it,
   and `pendingAnswer(uid:addresses:)` reads it back from that row.

Once the drainer has sent the answer, the row is gone. The message, reopened, shows
**Accept · Decline · Tentatively accept** again, although the server's calendar holds the
answer and the web shows "already reacted". WS-44's audit filed this as D-3.

## Decision

Accepted for v2. The card shows what the mirror can prove: an answer still in the queue, or
one carried by the attached copy. Answered-and-sent invitations show the buttons again.
Answering again is safe: the write lands on the copy the calendar already holds for that
UID (ADR-0093), so a second answer replaces the first rather than duplicating the event.

## Consequences

- One parity gap that the user can see: after the queue drains, a reopened invitation looks
  unanswered here and answered in the web.
- No wrong state is ever shown. The card never claims an answer the mirror cannot see; it
  only fails to claim one it could have learned from the server.
- A second answer is a real write and a real REPLY to the organiser. Pressing the same
  button twice tells the organiser the same thing twice; pressing a different one changes the
  answer, which is what the user asked for.
- Nothing is added to the sync engine: no per-message CalDAV request from a view (the network
  never renders), no new mirrored table.

## Alternatives considered

- **Remember sent answers locally** (a row keyed by UID when the operation drains). Lost
  when the answer is changed in the web or on another device, so it would show a stale answer
  as fact. Worse than showing the buttons.
- **Ask CalDAV for the UID when the card appears.** A network read on render, which the
  architecture forbids, and an answer that is missing offline exactly when the rest of the
  card works.
- **Mirror calendar objects.** The right fix, and too large for a card: a REPORT per calendar,
  sync tokens, recurrence storage. It is the revisit trigger.

## Revisit when

Calendar objects are mirrored (a `calendarObject` table synced like contacts). The card then
reads the user's PARTSTAT from the mirrored copy of the UID, as the web does from CalDAV.
