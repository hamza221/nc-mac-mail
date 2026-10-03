<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0053: Settings builds its own short-lived sync objects rather than reaching into `AccountEngine`

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-12, from reading `AccountEngine.swift` as landed by WS-13

## Context

Settings › Storage needs four things `AccountEngine` (`NextcloudMail/App/AccountEngine.swift`)
already runs one of, per account: pause and resume the backfill, run a deep reconcile on
demand, and answer the offline queue's depth before sign-out. `AccountEngine` runs exactly
one `MirrorCoordinator`, one `SyncScheduler` and one `OperationDrainer` per account row, and
its own doc comment is explicit that it is "the only file in the app target that imports
`NCMailSync`."

`NCMailSync` (WS-04/05/06) and `NextcloudMail/App/**` (WS-13) are both outside what this
workstream owns, and `AccountEngine` was being edited by another agent while this one ran, so
neither could be changed here. `AccountEngine.account(id:)` today returns only the account's
session and a `BodyPrioritising` view of its mirror; it exposes no pause, no reconcile and no
drainer.

## Decision

`SettingsStore` imports `NCMailSync` itself and builds a `MirrorCoordinator`, `SyncScheduler`
or `OperationDrainer` of its own, against the same `MailStore` and the account's real
`MailClient`, for exactly the four actions above. Nothing else in the app target besides
`AccountEngine` does this; Settings is now the second and, for the reasons below, this
should not become a pattern other views copy.

## Consequences

- Every Settings action this workstream's brief lists works today, against the live server,
  without any change to `AccountEngine`.
- **Sign-out is exact.** `OperationDrainer.summary()`, `.drain()` and `.discardAll()` are
  reads and writes of the `pendingOperation` table; a drainer built fresh for the question
  answers exactly as the real one would, because nothing about the answer depends on being
  the same actor instance.
- **Pause, Resume, Re-download and Check for missing messages are not exact while a real
  `MirrorCoordinator` is also running the account**, which only overlaps during the one-time
  initial backfill. A fresh coordinator's `.pause()` sets `account.mirrorState` and the
  persisted flag but does not stop the real coordinator's in-flight requests; the real one
  keeps going until its own pass ends. Settings' own coordinator is cached per account
  (`SettingsStore.coordinators`) so a second Pause or Resume in the same Settings session
  acts on the instance the first one started, but that cache does not survive the Settings
  window closing and reopening, so a Resume started, then abandoned by closing the window,
  cannot be Paused again from a freshly reopened window; the underlying `MirrorCoordinator`
  keeps running regardless (its own internal task holds a strong reference to itself), so
  data correctness is never at risk, only the control's promptness.
- The two per-account coordinators (Settings' and `AccountEngine`'s) share
  `MirrorBudget.shared`'s process-wide concurrency cap, so the failure mode is redundant
  `bootstrap()` calls and a duplicated stage-1 scan, not a thundering herd of body fetches.
- `SettingsStore.pauseMetaKey(_:)` duplicates the exact string
  `MirrorCoordinator.pauseKey(_:)` builds privately, because nothing exposes it. A rename on
  either side breaks Pause silently rather than at compile time.

## Alternatives considered

**Wait for `AccountEngine` to expose what Settings needs, and stub the four actions until
then.** Rejected: the brief's acceptance criteria are checkable today, against the live
server, and "do everything that is not blocked first" is the house rule. Waiting on a file
being actively edited by another agent is exactly the kind of cross-workstream idling
`CLAUDE.md` asks against.

**Have `AppSession`/`AccountEngine` grow a `controls(id:) -> AccountControls?` accessor
(pause, resume, deepReconcile, drainer) that Settings calls into.** This is the correct fix,
and it removes every consequence above. It needs a change to `NextcloudMail/App/**`, which
this workstream cannot make. Recorded here as the concrete shape the next agent to touch
`AccountEngine` should build, rather than left only in the report where it is easier to lose.

## Revisit when

`AccountEngine` grows an accessor for its running coordinators, drainer and scheduler. At
that point `SettingsStore` should take it as a dependency and stop constructing its own,
and `pauseMetaKey(_:)` should be deleted in favour of whatever `MirrorCoordinator` exposes
publicly, or a `MailStore` reader that names the flag instead of a string both sides guess
at.
