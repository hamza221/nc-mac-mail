<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0046: `MailboxTree` takes its own row type, not `NCMailCore.Mailbox`

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-07, against the illustrative signature in `docs/delivery/briefs/WS-07-sidebar.md`

## Context

The brief sketches `MailboxTree.build(from mailboxes: [Mailbox], delimiter: String?) ->
[MailboxNode]`, and `Mailbox` (`NCMailCore/Models/Mailbox.swift`) already has `leafName`,
`isSubscribed` and `isSelectable` — exactly the fields a tree builder wants. Using it looks
like the obvious choice.

It is the wrong one. `Mailbox.id` decodes the server's `databaseId`, and
[ADR-0033](0033-accounts-have-a-local-identity.md) exists because that number is not unique
across servers — "two Nextcloud servers each have a mailbox 5." The sidebar's `List
(selection:)` binds one `Int64?` across every account it draws (S-10), so a tree keyed by
`Mailbox.id` would let two accounts' mailboxes collide under the same selection value, which
is the exact bug ADR-0033 was written to close. The type that carries the right id is
`NCMailStore.MailboxRecord`, and `NCMailCore` must not import `NCMailStore` — dependencies
point downward only ([overview.md](../architecture/overview.md#modules)) — so `MailboxTree`
cannot be written against it either.

A `Mailbox` also cannot be built from a `MailboxRecord` without decoding JSON: it has no
public memberwise initialiser, only `init(from: Decoder)`. The record does carry the
original payload in `rawJSON`, but decoding it in the view layer is exactly what
`NextcloudMail`'s module rules forbid — "read a JSON payload directly" is in its Must-not
column ([overview.md](../architecture/overview.md#modules)) — so that path is closed too.

## Decision

`MailboxTree.swift` defines its own dependency-free row type, `MailboxTreeRow`: the seven
plain fields (`id`, `name`, `delimiter`, `specialRole`, `isSelectable`, `isSubscribed`,
`unreadCount`) the tree needs, with a local `Int64` id. `NextcloudMail/Views/Sidebar`
converts a `MailboxRecord` into one with a plain memberwise mapping — no JSON, no GRDB, and
nothing outside what the app target already touches.

`MailboxNode.row` is `Optional`, not the non-optional `mailbox: Mailbox` the brief sketched,
because a synthetic container node — the one this file invents when a child's parent path
has no row of its own — has no real row to hold. The view distinguishes a synthetic
container from a real `\noselect` one by `isSelectable`, not by whether `row` is nil; both
render the same way.

## Consequences

- The pure function stays exactly as testable as the brief wanted: `MailboxTreeTests`
  builds `MailboxTreeRow` values by hand, no fixture, no store, no I/O.
- The sidebar carries one small conversion (`MailboxRecord` → `MailboxTreeRow`) that the
  brief's sketch did not show. It is a handful of lines in `Views/Sidebar`, not a new
  package dependency and not a new public type on `MailboxRecord` itself — `NCMailStore` is
  not this workstream's to change.
- If `NCMailCore.Mailbox` ever grows a memberwise initialiser for some other reason, this
  decision does not change: the id problem is still there.

## Alternatives considered

**Use `NCMailCore.Mailbox` as the brief shows it.** Rejected: reintroduces the cross-server
id collision ADR-0033 closed, for exactly the type (the sidebar's selection) ADR-0033's own
motivating example uses.

**Give `NCMailStore.MailboxRecord` a protocol conformance to a `NCMailCore` protocol,
declared from the app target.** Considered and rejected: `MailboxRecord` is owned by WS-03,
actively being edited elsewhere while this workstream runs, and a retroactive conformance
declared in a third module is exactly the kind of thing Swift's `@retroactive` warning
exists to flag — worse ergonomics than a seven-field struct for no real gain.

**Add a memberwise initialiser to `NCMailCore.Mailbox`.** Out of scope: `Models/Mailbox.swift`
belongs to WS-02, not to `MailboxTree.swift`'s carve-out.

## Revisit when

`NCMailCore` grows a store-shaped type that already solves the id problem for some other
reason — at that point `MailboxTreeRow` may be redundant with it.
