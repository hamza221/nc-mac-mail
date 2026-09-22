<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0031: The app pushes the network path into the mirror; the mirror reads the power state itself

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-04, wiring etiquette rule 4

## Context

Rule 4 of [local-mirror.md](../architecture/local-mirror.md#stage-2--bodies): "Low Power
Mode, or an `NWPath` that is `isExpensive` or `isConstrained`, pauses stage 2 (never stage 1,
which is cheap and makes the app usable)." Three conditions, and they do not come from the
same place.

WS-13 put the one `NWPathMonitor` in `NextcloudMail/Status/NetworkMonitor.swift`, deliberately:
the backfill, the sync scheduler and the drainer must read one answer rather than each run a
monitor and disagree for a moment at the edge of a change. `NCMailSync` cannot import an
app-target type, so it cannot read that monitor.

Low Power Mode is not on the path at all. It is `ProcessInfo.isLowPowerModeEnabled`, with its
own notification, and nothing in the app watches it.

## Decision

Two different mechanisms, because they are two different facts.

**The path is pushed in.** `MirrorCoordinator.apply(conditions:)` takes a
`MirrorConditions` value — `isOffline`, `isExpensive`, `isConstrained` — and the app-side
glue calls it from the shell's single monitor. Offline stops the whole mirror; expensive or
constrained stops stage 2 only.

**The power state is read here.** `MirrorConfiguration.isLowPowerModeEnabled` is a closure
defaulting to `ProcessInfo.processInfo.isLowPowerModeEnabled`, consulted each time stage 2
decides whether to carry on, and the coordinator subscribes to
`NSProcessInfoPowerStateDidChange` itself so that plugging in resumes the backfill.

## Consequences

`NCMailSync` has no `Network` import and no monitor of its own, so the rule WS-13 wrote down
survives contact with the first subsystem that needed it. WS-05 and WS-06 take the same
value through the same door.

Reading power inside the package means one more thing for the shell not to have to wire, and
one fact the package cannot get wrong by being told late. It also makes both conditions
injectable: `MirrorConfiguration` is how the tests turn Low Power Mode on without a battery,
and `apply(conditions:)` is how they turn the network off without one.

The asymmetry is the cost. A reader who finds `apply(conditions:)` will reasonably expect
Low Power Mode to be in it, and it is not. The type's documentation says why at the point
where the question occurs.

`MirrorCoordinator.pauseReason` reports whichever condition is holding the most back,
including one that is only holding stage 2, because
[user-stories.md](../product/user-stories.md) S-02 asks the progress UI to say *why*. "Still
enumerating, bodies held for Low Power Mode" is the useful sentence, and it needs both
halves.

## Alternatives considered

**An `NWPathMonitor` in `NCMailSync`.** Two monitors, two answers during a transition, and
the sidebar saying "offline" while the backfill carries on. WS-13 already rejected this and
wrote down why.

**A protocol the app conforms to.** `MirrorConditionsProviding`, implemented by the shell,
injected at init. An extra type, a retain cycle to think about, and a push model rendered as
a pull one. `apply(conditions:)` is the same information with nothing to own.

**Push the power state too.** Consistent, and it means the app has to learn about a
notification whose only consumer is the backfill. It also makes the package's behaviour
depend on the app remembering to call it, which is the kind of wiring that is missing in
exactly the build where someone tests on battery.

## Revisit when

A second subsystem needs the power state, at which point it belongs next to the path monitor
in the shell and both arrive through `apply(conditions:)`.
