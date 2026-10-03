<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0048: The status footer adds every account's progress into one line

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-13, wiring `MirrorCoordinator.progress` into `AppStatus`

## Context

`AppStatus.mirror` is one `MirrorProgress?` and the footer is one line, because
`docs/product/ux-spec.md#sidebar` says idle chrome is noise and gives the footer a priority
order rather than a stack. `MirrorProgress` is published per coordinator, and there is one
coordinator per account. Two accounts, two streams, one slot.

Assigning each value as it arrives — the first shape this code had — makes the footer flip
between two counts a second apart, and shows "12,431 of 48,902" for whichever account
published last. That is not a small cosmetic problem: the number is the only evidence the
first-run backfill is progressing at all, and a number that jumps backwards reads as a stall.

## Decision

`AccountEngine` keeps the latest `MirrorProgress` per account and adds the four counts
together into the one value `AppStatus.mirror` holds.

`MirrorProgress.isComplete` is `mailboxesRemaining == 0 && bodiesPresent + bodiesFailed ==
totalMessages`, which holds for a sum exactly when it holds for every part, so the footer
clears when the last account finishes rather than when the first one does.
`AppStatus.pendingFailures` is summed the same way, from each drainer's `PendingSummary`.

## Consequences

- One line, one monotonic pair of numbers, for any number of accounts.
- The footer says "Downloading messages — 428 of 1,030" without saying which account. With one
  account, which is the common case, that is exactly right. With two it is a total, which is
  what a progress line is for.
- An account that is paused or stalled contributes its counts and no explanation.
  `MirrorPauseReason` is per coordinator and is not in `MirrorProgress`, so the footer cannot
  distinguish "paused" from "slow" today. S-02 asks for that distinction and it is not built;
  it is a per-account statement and belongs in the storage panel (WS-12) rather than in a
  one-line footer.
- `AccountEngine.combined(progress:)` is `nonisolated` and pure, which is what makes the
  arithmetic testable without a coordinator, a client or a database.

## Alternatives considered

**Show the account that is furthest behind.** More honest per account, and it needs the
account's name beside the number to mean anything, which turns one line into two or into a
truncated name. Rejected against the ux-spec's one-line footer.

**Show only the first account's progress.** Cheapest, and it tells a two-account user that
their second account is finished when it has not started.

**Widen `AppStatus.mirror` to a dictionary and let the footer decide.** Moves the same
decision into a view, and the view would have to make it on every redraw.

## Revisit when

The storage panel exists and there is somewhere to say per-account state properly, or a user
with two large accounts reports that one total is less useful than a name and a number.
