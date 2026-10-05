<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0102: The Contacts sidebar has no "Not grouped" entry

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-44's parity audit (defect D-4 against WS-35), on the code as built:
`ContactsScope`, `ContactsSidebarSection` and `ContactsListing`

## Context

Web Contacts lists, under its groups, a **Not grouped** entry: every contact whose vCard has
no `CATEGORIES` value. WS-35 built the Contacts section from `ContactsScope` (ADR-0070) —
All contacts, Favorites, each address book, each contact group (one per `CATEGORIES` value),
the Teams, Recently contacted — and no scope means "no group". The parity row C4 was marked
Done with that gap stated in its evidence; WS-44's audit filed it as D-4 because no record
said it was a choice.

## Decision

Accepted for v2: the sidebar offers no "Not grouped" entry. Contacts without a group are in
All contacts and in their address book, which is where the list's search and sort already
work.

## Consequences

- One web entry missing. Someone tidying contacts into groups has no list of what is left
  and has to go through All contacts instead.
- `ContactsScope` stays a set of things a contact *has* (a book, a group, a team, a star),
  each a plain filter over mirrored rows. "Has no group" would be the first negative scope.
- Nothing else depends on the absence. A later case is additive: one `ContactsScope` case,
  one filter (`categories` empty) in the listing, one sidebar row with its count.

## Alternatives considered

- **Add the case now.** Small, and outside the defect-fix scope the audit set: a new scope is
  a selection that persists (`SidebarSelection` is `Codable`), a count query and a sidebar
  row, which want a workstream's tests rather than a fix's.
- **Show ungrouped contacts under a pseudo-group named "Not grouped".** A group of that name
  would collide with a real `CATEGORIES:Not grouped` value and be written into vCards by the
  editor's group chips. Rejected.

## Revisit when

Someone needs the list, or Contacts gains a reason to add a negative scope: the change is a
`ContactsScope.notGrouped` case filtering cards with no `CATEGORIES`, placed after the groups
as the web places it.
