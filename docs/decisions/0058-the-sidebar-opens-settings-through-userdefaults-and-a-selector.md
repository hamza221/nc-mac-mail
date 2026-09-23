<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0058: The sidebar opens Settings through a `UserDefaults` key and an AppKit selector

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-12, on the two hooks its brief names as its own in WS-07's file

## Context

`SidebarStore.showStorage(_:)` and `.signOut(_:)` (`NextcloudMail/Views/Sidebar/SidebarStore.swift`)
were WS-07's placeholders, logging and stopping because nothing existed for them to do yet.
This workstream's brief assigns those two method bodies to it by name, even though the rest
of that file belongs to WS-07.

`SidebarStore` is a plain `@Observable` class, not a `View`, so it has no
`@Environment(\.openSettings)` to call and no way to bind a `TabView`'s selection directly.
Whatever it does has to reach the Settings window and its already-open (or about-to-open)
`TabView` from outside the view hierarchy entirely.

## Decision

`showStorage(_:)` writes `"storage"` and `signOut(_:)` writes `"accounts"` to the
`UserDefaults` key `SettingsTab.preferredTabKey`, then both call
`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`, the same AppKit
selector the "Settings…" menu item itself sends. `SettingsRootView` reads that key once, at
its own `init`, into the `@State` that drives its `TabView`'s selection
(`NextcloudMail/Views/Settings/SettingsScene.swift`).

Neither method performs the action itself. `showStorage` opens the Storage tab; `signOut`
opens the Accounts tab, where the confirmed Sign Out button and its two-question flow
already live. The sidebar is not where a destructive action gets confirmed.

## Consequences

- Both hooks now do something a user can see, without either file reaching into the other's
  types beyond naming `SettingsTab` directly, which same-target visibility already allows.
- The coupling is a string literal (`"settings.preferredTab"`) that has to agree between
  `SidebarStore.swift` (WS-07) and `SettingsScene.swift` (WS-12). `SettingsTab.preferredTabKey`
  is the one place the string is spelled; `SidebarStore` names that constant rather than
  its own copy of the string, which is the whole of what keeps this from silently drifting.
- The Settings window opens on the *last requested* tab only until the user switches tabs by
  hand; nothing pins it there. That matches how System Settings' own deep links behave and
  needed no extra state.
- Untested by this workstream's own suite: `NSApp.sendAction` opens a real window and has no
  useful assertion in a unit test. Verified by code inspection and by confirming
  `make build-app` and `make lint` stay clean; there is no GUI in this environment to
  screenshot the result (see the report).

## Alternatives considered

**A closure property on `SidebarStore`, set by `AppSession` or `RootSplitView`, calling
`openSettings(_:)` from the environment.** More testable and idiomatic SwiftUI, and the
better answer long-term. Rejected for now because wiring the closure means editing
`AppSession`/`RootSplitView`, both WS-13's files and being edited by another agent while
this one ran.

**Do nothing, and leave both hooks logging.** That is what they were before this workstream;
the brief asks for more, and a hook that only ever logs is a worse outcome once something
downstream (a support conversation, a user report) depends on the click actually doing
something.

## Revisit when

`AppSession` grows a typed way to open Settings on a given tab (an `@Environment` action or
a method), at which point `SidebarStore` should call that instead of going through AppKit
and `UserDefaults` directly.
