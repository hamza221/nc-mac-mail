# ADR-0007: Mirror subscribed mailboxes only

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Product owner

## Context

"Download your whole IMAP" needs a boundary. Many accounts carry mailboxes the user has
deliberately hidden in the web client — shared folders, archives of a former team,
`Trash` on a server that never prunes it. IMAP subscription is the existing, user-set
expression of "I care about this folder", and Nextcloud Mail already honours it through
the per-account `showSubscribedOnly` setting.

## Decision

The backfill mirrors mailboxes whose IMAP attributes include `\subscribed`. Everything
else still appears in the sidebar, still opens, and fills on demand.

Mechanically: the mailbox payload has no `subscribed` field. Subscription arrives inside
`attributes`, the raw IMAP attribute list, and is compared **case-insensitively** — Horde
passes server casing through, and the Vue client compares against lowercase
`\subscribed` (`src/components/NavigationMailbox.vue:289`). The same array carries
`\noselect`, which marks a mailbox that cannot be opened at all; the client derives
`isSelectable` from it, because the server's `selectable` column is not serialised into
the payload.

## Consequences

- The mirror respects a choice the user already made, in the place they already made it.
- Disk and backfill time drop on exactly the accounts where they would otherwise hurt
  most.
- An unsubscribed mailbox is not second-class: it lists and reads, just without a local
  copy ahead of time. Offline, it shows what was opened before.
- **Local search does not cover unsubscribed mailboxes**, and the search UI must say so
  rather than silently return less. This is the real cost of this decision.
- Subscribing to a mailbox in the web client starts mirroring it on the next mailbox-list
  sync; unsubscribing stops the backfill and keeps what is already local.
- Servers that do not implement subscriptions report everything subscribed, which
  degrades gracefully into "mirror everything".

## Alternatives considered

**Every mailbox, including Trash and Junk** — the literal reading, and the one that makes
search complete. Rejected: it spends the most bandwidth and disk on the folders with the
least value, and it ignores an explicit user signal.

**Everything except Trash and Junk.** Hard-codes our taste over the user's; a user who
subscribed to Junk on purpose gets overruled.

## Revisit when

Users report missing search results often enough to matter. The likely answer is then a
per-mailbox "keep a local copy" toggle in Settings, with subscription as its default — a
small change, because `mailbox.isMirrored` is already a column rather than a derived
value.
