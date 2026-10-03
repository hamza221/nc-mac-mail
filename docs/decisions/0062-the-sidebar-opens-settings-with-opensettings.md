<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0062: The sidebar opens Settings with `openSettings`, and the tab is bound to its key

**Status:** Accepted, supersedes [ADR-0058](0058-the-sidebar-opens-settings-through-userdefaults-and-a-selector.md)
**Date:** 2026-10-03
**Decided by:** first manual QA pass, after "Storage…" did nothing

## Context

ADR-0058 had `SidebarStore` write the wanted tab to `UserDefaults` and then send AppKit's
`showSettingsWindow:` selector. On macOS 14 and later that selector no longer opens a SwiftUI
`Settings` scene. Every click logged the runtime issue "Please use SettingsLink for opening
the Settings scene" and nothing appeared. The tab was also read once into `@State`, so an
already-open window would have stayed on its old tab.

## Decision

- `SidebarStore.showStorage` and `.signOut` only write `SettingsTab.preferredTab`.
- The sidebar's account menu, which is a view, calls `@Environment(\.openSettings)` right
  after.
- `SettingsRootView` binds its `TabView` selection with `@AppStorage` to the same key, so a
  request switches the tab even when the window is already open, and the window reopens on
  the tab last used.

## Consequences

- "Storage…" and "Sign out" open Settings on the right tab, using public API.
- Opening a window is the view's job, the one place SwiftUI makes it available. The store
  says which tab and the view opens the window.

## Alternatives considered

**`SettingsLink` in the menu.** Also public, but it opens the window without letting the
store pick a tab first. The tab could only be chosen with a gesture modifier, which menus
don't reliably run.

## Revisit when

SwiftUI offers a way to open Settings on a specific tab.
