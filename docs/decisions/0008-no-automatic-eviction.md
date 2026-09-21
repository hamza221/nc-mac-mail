# ADR-0008: No automatic eviction; the user manages storage

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Product owner

## Context

A cache with a ceiling needs an eviction policy. Every eviction policy eventually deletes
something someone wanted, and in a mail client the user cannot tell the difference between
"evicted to save space" and "lost".

## Decision

The mirror has no automatic eviction and no size ceiling. Instead, **Settings › Storage**
shows what is being used per account and offers explicit controls:

- **Remove local copies** — drops bodies, inline image data and search rows for an account,
  keeps envelopes, and leaves the app working. Bodies re-fetch on open.
- **Re-download** — clears the same and restarts the backfill.
- **Pause backfill** — persists across launches.

Every confirmation says, in those words, that it removes **local copies only** and does not
touch mail on the server.

## Consequences

- A message that was mirrored stays mirrored. Search results do not decay, and offline
  reading does not become a lottery.
- A user with a very large mailbox and a small disk can be surprised — mitigated by showing
  the size during the first backfill, not only after it.
- Disk-full is handled explicitly: pause the backfill, surface it once in the storage panel
  with the amount needed, never crash or corrupt.
- Nobody has to write, test, or defend an eviction heuristic.

## Alternatives considered

**Soft cap with oldest-body eviction, envelopes kept.** The conventional answer, and not
unreasonable: the list stays complete and old mail re-fetches on open. Rejected because it
makes local search quietly incomplete in a way the user cannot see or predict — "I searched
and found nothing" is indistinguishable from "it was evicted".

**Time-based retention (bodies older than a year).** Same objection, arbitrary constant.

## Revisit when

Real users run out of disk. The fix is then more likely to be per-mailbox opt-out (see
[ADR-0007](0007-subscribed-mailboxes-only.md)) than an automatic policy.
