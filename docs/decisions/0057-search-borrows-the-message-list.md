<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0057: Search borrows the message list instead of drawing its own

**Status:** Accepted, with one thing still owed
**Date:** 2026-09-23
**Decided by:** WS-11

## Context

[ux-spec.md](../product/ux-spec.md#search) asks for four things from a result: it replaces
the list, matches are highlighted with `NCHighlightText`, the row names its mailbox because
"all mail" spans folders, and the list keeps windowing.

WS-08 left a seam for the first and the last of those: `MessageListStore.filteredSource`, a
`(Range<Int>) -> StoreObservation<[MessageRow]>` the list opens its window on instead of the
mailbox query. Everything the list already does — windowing, sections, selection, the
no-results screen, the live updates when sync writes — comes free with it.

The other two are row-level. `MessageListRow` draws a subject, not a highlighted subject,
and has no mailbox name to draw because a row in a mailbox does not need one. Both live in
`NextcloudMail/Views/MessageList/**`, which belongs to WS-08.

## Decision

Install the seam. `SearchModel.rowSource()` goes into `filteredSource` and the existing list
draws the results.

The store also has `search(_:limit:offset:)`, which returns `SearchResult` with
`mailboxName` and `accountId` next to the row. The list uses `observeSearchRows(_:range:)`
because the seam takes `MessageRow`. A live `SearchResult` reader (`observeSearch`) was
removed as dead code on 2026-10-03, and comes back with highlighting, which needs it.

Highlighting and the mailbox name are **not** shipped. They are a change to `MessageListRow`
and that is a request to WS-08, not an edit from here.

## Consequences

- Search has no list of its own, so there is no second windowing implementation to drift
  from the first. A fix to how the list windows, selects or sections fixes search too.
- Selection, keyboard triage (WS-10) and the detail column work under a search with no extra
  wiring: the rows are the same rows.
- `SearchResult.mailboxName` has no reader in the app today. It is the honest public answer
  for a caller asking "where did this come from" and the field the row will read once
  `MessageListRow` can draw it.
- Two of the UX specification's four bullets are outstanding. That is written down here and
  in the workstream report rather than quietly dropped.

**What WS-08 is asked for:** two optional parameters on `MessageListRow` — `matching: String`
to pass to `NCHighlightText` for the sender and subject, and `mailboxName: String?` for a
caption when it is non-nil — plus the two lines in `MessageListView` that pass them down from
the filter. Nothing else about the row changes, and an unfiltered list passes neither.

## Alternatives considered

**A second list in `Views/Search/`.** It would ship all four bullets today. It also means a
`List`, a `ForEach` over sections, a window-extension trigger and an empty-state overlay that
have to keep agreeing with WS-08's copies of the same four things, and WS-08's hand-off asked
for exactly this not to happen.

**Edit `MessageListRow` anyway.** One small change, in another workstream's finished work,
while three agents are in the tree. The house rule says write it in the report instead, and
the rule is right: two agents producing one conflict and two half-fixes is the failure it
exists to prevent.

**Put the mailbox name in the section header.** "All mail" results are ordered by relevance,
so consecutive rows come from different folders and the sections would be one row each.
