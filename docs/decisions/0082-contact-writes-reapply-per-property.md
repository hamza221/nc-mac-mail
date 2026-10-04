<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0082: A contact write that meets a 412 reapplies the edited properties once; local wins a same-field race; a second 412 parks a conflict row

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-24 (contacts mirror), measured against the live server

## Context

ADR-0069 says contact writes carry `If-Match` and that a 412 is answered by refetching and
reapplying the locally edited properties. It does not say what the unit of a "property" is,
who wins when both sides changed the same one, how often to retry, or where a write that
cannot be landed goes. The offline queue (WS-22) parks failures as rows the user can retry
or discard; the store has no conflict table.

## Decision

- **The unit is the property name.** A queued `contactPut` carries `editedProperties`, the
  vCard names whose lines differ between the card the user started from and the card they
  saved (`ContactMerge.editedProperties`), ignoring `VERSION`, `PRODID` and `REV`.
- **On 412:** fetch the server's card with a one-href `addressbook-multiget`, start from it,
  and replace every line of each edited name with the local lines (removing them if the user
  removed them). Every other line is the server's, untouched. PUT once more with the fresh
  ETag.
- **Same field changed on both sides: local wins.** It is the user's latest explicit act on
  this device, and it is in flight. The conflict is logged — `ContactConflictLog` and OSLog
  with the property name only — not shown as a prompt.
- **A second 412 gives up.** The handler throws `preconditionFailed`; the queue keeps the row
  with `lastError = "conflict"`, visible with Retry and Discard. That row is the conflict row
  ADR-0069 asks for: no new table. Retry runs the reapply again; Discard reverts the local row
  to the `before` snapshot. A sync never overwrites a card with a queued or parked write.
- **Deletes win too.** A `DELETE` that meets a 412 deletes the newer copy with its fresh ETag,
  once, and logs it.
- **A card deleted on the server while edited here** is created again from the local copy.

## Consequences

- A colleague's edit of a phone number survives our offline edit of an email address
  (`concurrentEditOfADifferentFieldMerges`), and neither user is asked anything.
- Two people editing the *same* field concurrently: the later-synced device wins and the
  earlier value is lost from the card. That is what web Contacts does too (it PUTs without
  merging); here it is at least logged.
- Granularity is coarse for multi-valued names: if the user edits one of three EMAIL lines
  and the server edits another, local wins all three. Lines have no identity in a vCard
  (order and TYPE are rewritten by other clients), so finer matching would guess.
- In testing, the reapply fell through to a conflict row only when the test forced a second
  412; against the live server it never did.

## Alternatives considered

**Server wins on a same-field conflict.** Silently drops what the user typed while offline,
which is the failure ADR-0003 exists to prevent.

**Prompt the user to choose.** A modal about a phone number, possibly hours after the edit,
for a race that is rare in a personal address book. The queue's conflict row already covers
the case that cannot be resolved automatically.

**Retry the reapply until it lands.** Two consecutive 412s mean a live writer racing us; a
loop would fight it. One retry, then a row the user can see.

**A `contactConflict` table.** The queue row already persists the write, its `before` and its
state, and already has Retry/Discard UI.

## Revisit when

Users report lost same-field edits, or a CardDAV client starts writing per-line identifiers
(`PID`/`CLIENTPIDMAP`) that would let lines be matched.
