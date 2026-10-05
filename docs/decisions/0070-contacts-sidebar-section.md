<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0070: Contacts appear as a sidebar section, under the mail accounts

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** product owner, v2 planning

## Context

v2 adds Contacts (ADR-0064), and it needs a home in the window. The app is a three-column
mail window with one sidebar. Contacts could be a second window, a module switcher, or a
part of the sidebar it already has.

## Decision

Contacts appear as a sidebar section, under the mail accounts.

- Layout: one `List(selection:)` sidebar. Per Nextcloud login there is a "Contacts"
  section listing All contacts, Favorites, each enabled address book, contact groups,
  Teams (when available) and Recently contacted.
- Columns: picking one turns the content column into the contact list and the detail
  column into the contact card.
- Why: the user wants Contacts to feel part of the app. A second window and a module
  switcher both lost.

## Consequences

- Contacts feel part of the app: same window, same selection model, same three columns,
  and switching between mail and a contact is one click in one list.
- The cost is a longer sidebar — every login adds a Contacts section under its mail
  accounts — and the content and detail columns must handle a second content type.

## Alternatives considered

**A second window.** Contacts stop feeling part of the app; window management is the
user's problem.

**A module switcher (web-style app toggle).** A mode the user must notice and leave; the
sidebar already expresses "sections per login" naturally.

## Revisit when

The sidebar grows enough sections per login that one list stops scaling, or Contacts
grows surfaces a single detail column cannot hold.
