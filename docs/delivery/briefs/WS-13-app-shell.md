<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-13 — App shell, theme, restoration, status

**Wave 3, after WS-01 and WS-02. Size: M. Parallel with WS-07, WS-08, WS-09.**

## Goal

The window everything else lives in: three columns, the instance's brand colour, state that
survives a relaunch, and one honest status indicator.

## Before you start

- [../../product/ux-spec.md](../../product/ux-spec.md) — window section
- [../../reference/ui-components.md](../../reference/ui-components.md) — theme installation
- `hamza221/nextcloud-swiftui` README — theming, and why `.ncTheme` sets `.tint`
- [../../product/user-stories.md](../../product/user-stories.md) — S-09, S-10

## You own

`NextcloudMail/App/**`, `NextcloudMail/Theme/**`, `NextcloudMail/Status/**`,
`NextcloudMail/MailSymbol.swift`

## Build

**The scene.** `@main`, a `WindowGroup` with a three-column `NavigationSplitView`,
`.ncTheme(theme)` at the root, a `Settings` scene, and the `Commands` WS-10 populates.

**Branding.** `GET /ocs/v2.php/cloud/capabilities` →
`data.capabilities.theming.color` → `NCBrand(primaryHex:)` → `NCTheme(brand:)`. Cache the
colour in `meta` and apply it **before the first frame**, so the app does not visibly
re-theme a second after launch. Refresh it on each launch in the background.

**`MailSymbol`** — the single file mapping every icon this app uses to either an `NCSymbol`
from the catalogue or an SF Symbol fallback, with a comment per fallback naming the MDI
icon the library is missing:

```swift
enum MailSymbol {
    case inbox, sent, drafts, archive, junk, trash, folder, star, attachment, unread, sync, tag, answered
    var view: some View { … }        // NCIcon when the catalogue has it, Image(systemName:) when not
}
```

WS-00's lint rule bans `Image(systemName:)` everywhere else, so this file is the whole
substitution surface and swapping it out when the catalogue grows is mechanical.

**State restoration** — window frame, column widths, selected account and mailbox,
threaded/flat, sidebar expansion. Restoration, not preferences: `@SceneStorage` and `meta`,
not a settings panel.

**Status**, one place, priority order, and nothing when idle:

```swift
@MainActor @Observable
final class AppStatus {
    var mirror: MirrorProgress?        // WS-04 publishes
    var isOffline: Bool                // NWPathMonitor
    var pendingFailures: Int           // WS-06 publishes
    var display: StatusDisplay { … }   // exactly one thing, or nothing
}
```

**Multi-account** — accounts load from the Keychain at launch, each gets its own client,
mirror coordinator and scheduler, and one broken account does not block another.

**Session expiry (401)** — the one modal in the app, because nothing works until it is
fixed: "Your session has expired. Sign in again."

**`NWPathMonitor`** lives here and publishes offline state; the sync and backfill actors
observe it rather than each polling their own.

## Acceptance

- Launch shows three columns wearing the instance's brand colour, with no visible re-theme.
- Changing the colour server-side and relaunching recolours the app.
- Window size, columns, selection and expansion all restore.
- Two accounts both work; breaking one (revoke its app password) leaves the other alone.
- The status area shows exactly one thing at a time and nothing when everything is fine.
- Airplane mode flips the indicator within a second and nothing else changes.
- 401 produces the sign-in prompt and, after signing in, work resumes without a relaunch.
- Sidebar icons are MDI glyphs from Xcode **and** in a signed Release build — check both,
  because only the first has ever been verified.

## Out of scope

The contents of any column (WS-07, WS-08, WS-09). Settings contents (WS-12). Login UI
(WS-01 — you host it).

## Report

Additionally: the MDI-versus-SF-Symbol substitution list from `MailSymbol`, which goes
straight into [../../feedback/library-feedback.md](../../feedback/library-feedback.md); and
whether `.ncTheme` setting `.tint` globally was right for a mail client or wanted
`NCAccentPolicy.brandSurfacesOnly`.
