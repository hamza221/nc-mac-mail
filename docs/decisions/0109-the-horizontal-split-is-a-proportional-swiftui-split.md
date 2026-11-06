<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0109: The horizontal split is a proportional SwiftUI split, not `VSplitView`

**Status:** Accepted
**Date:** 2026-11-04
**Decided by:** pre-release QA on a Developer ID build against the live account, with
screenshots of each attempt

## Context

The `horizontal-split` layout ([ux-spec.md](../product/ux-spec.md), WS-29) put the list
above the message in a `VSplitView`. On a real window it failed three ways:

- With nothing selected, both panes were a narrow strip in the middle of the window: a
  `VSplitView` is only as wide as its panes ask.
- The message pane opened at its 160 pt minimum, so a selected message showed its header
  and smart replies and no body.
- Growing the window gave every point to the list. The divider was back at the minimum
  after every resize and every launch.

`.frame(maxWidth: .infinity)` on both panes fixed the width. Giving both panes the same
`idealHeight` did not change the first layout. Reaching the `NSSplitView` behind
`VSplitView` was tried twice. Setting holding priorities on it directly crashed at launch,
because AppKit asserts in `-[NSSplitView setHoldingPriority:forSubviewAtIndex:]`. Its
delegate is not an `NSSplitViewController`, so there are no items to set them on.
Re-positioning the divider whenever the split view's frame changed did not hold either:
SwiftUI lays the panes out again afterwards.

## Decision

`ProportionalVSplit` in `MessageListLayoutHost.swift`: a `GeometryReader` and `VStack`
with the list above and the message below. Both panes fill the width and are clipped.
The list's height is a fraction of the available height, clamped so neither pane goes
below 160 pt. The divider is a `Divider` with a 7 pt hit area and the row-resize pointer;
a drag (measured in global coordinates, because the divider moves with it) sets the
fraction. The fraction is kept in `@AppStorage("messageList.horizontalSplitFraction")`,
starts at one half, and holds as the window resizes. For VoiceOver the divider is one
adjustable element ("Divider between the list and the message", value in percent, 5 %
per step).

## Consequences

- The message has room from the first launch, and the proportion survives resizing and
  relaunch.
- The divider is ours: it lacks `NSSplitView`'s double-click-to-collapse and the system
  `AXSplitter` role. VoiceOver gets an adjustable element instead.
- The fraction is per Mac, not per window and not on the server. The web client keeps no
  equivalent, so there is nothing to sync.

## Alternatives considered

- **Keep `VSplitView`, tune its `NSSplitView`.** Tried: one attempt crashed, the other did
  not hold (see Context).
- **An `NSSplitView` in an `NSViewRepresentable` hosting both SwiftUI panes.** Gives the
  native divider and its accessibility, but two hosting views and their environments to
  forward, for a split that only needs a drag. Worth it if the double-click collapse is
  missed.
- **A fixed proportion with no drag.** Simpler, and wrong: the reader decides how much
  list they want.

## Revisit when

SwiftUI gives `VSplitView` (or a successor) an initial position and holding priorities,
or someone asks for the collapse gesture.
