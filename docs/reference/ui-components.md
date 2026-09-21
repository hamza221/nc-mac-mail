<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# NextcloudUI in this app

*Which component goes where, with the real signatures, and what the library does not yet
give us. The second half is the point: this app exists partly to produce that list.*

Dependency: `.package(url: "https://github.com/hamza221/nextcloud-swiftui", branch: "main")`,
product `NextcloudUI`, which re-exports `NextcloudDesign` and `NextcloudIcons`. One import.

## Theme

Installed once at the scene root, re-assigned when capabilities arrive:

```swift
@State private var theme = NCTheme.nextcloud

WindowGroup { RootView() }.ncTheme(theme)

// after GET /ocs/v2.php/cloud/capabilities
if let brand = NCBrand(primaryHex: capabilities.theming.color) {
    theme = NCTheme(brand: brand)          // one assignment recolours the running app
}
```

`.ncTheme(_:)` also sets `.tint`, so the instance colour drives selection and focus rings,
overriding the user's macOS accent. That is the library's deliberate choice; if it proves
wrong for a mail client it is `NCAccentPolicy.brandSurfacesOnly`, no library change needed.
Record the finding either way.

Read tokens from `@Environment(\.ncTheme)`; never `@Environment(\.colorScheme)`. Spacing,
radius and avatar sizes come from `theme.metrics`, not from literals.

## Component map

| Screen | Component | Signature as it exists today |
| --- | --- | --- |
| Sidebar, account header | `NCNavigationCaption` | `NCNavigationCaption(_ title: String)` or with a trailing `action:` builder |
| Sidebar, mailbox row | `NCNavigationItem` | `NCNavigationItem(_ title: String, icon: NCSymbol? = nil, count: Int = 0)`, or with `actionsLabel:` + `actions:` for the context menu |
| Message list row | `NCListItem` | `NCListItem(_ title:, subtitle:, leading:, details:)` — the four-slot form is the Mail shape |
| Message list metadata | `NCListItemDetails` | `NCListItemDetails(date: Date?, unreadCount: Int = 0, formatter: NCRelativeDateFormatter = …)` |
| Avatars everywhere | `NCAvatar` | `NCAvatar(displayName:user:size:status:label:load:)`, `load` being `(@Sendable () async throws -> Image)?` |
| Message header sender | `NCUserBubble` | `NCUserBubble(displayName:user:size:status:load:action:trailing:)` |
| Recipients, tags | `NCChip` | `NCChip(_ text:, role:, tint:, onRemove:, leading:)` |
| Unread counts | `NCCounterBubble` | via `NCNavigationItem(count:)` and `NCListItemDetails(unreadCount:)` |
| Blocked content, phishing, errors | `NCNoteCard` | `NCNoteCard(_ role: .warning, title:, message:)` |
| Search result highlighting | `NCHighlightText` | `NCHighlightText(_ text: String, matching query: String)` |
| Toolbar buttons | `NCButtonStyle` | `.buttonStyle(.primary / .secondary / .tertiary / .error / .icon)` |
| Toolbar labels | `NCLabelStyle` | `.labelStyle(.nc)` / `.ncIconOnly` |
| Backfill progress | `NCProgressStyle` | `.progressViewStyle(.normal / .warning / .error)` |
| Icons | `NCIcon` | `NCIcon(_ symbol: NCSymbol, label: NCAccessibilityLabel, size: .small/.medium/.large)` |
| Shortcut hints in menus | `NCKeyboardShortcutLabel` | `NCKeyboardShortcutLabel(_ shortcut: NCKeyboardShortcut)` |
| Relative dates | `NCRelativeDateText` | `NCRelativeDateText(_ date: Date, formatter:)` |
| Empty states | **system** `ContentUnavailableView` | The library deliberately does not wrap it — see its `EmptyStates.md` |
| Settings | **system** `Form` + `.formStyle(.grouped)` | Likewise `SettingsSections.md` |

The showcase's `MailScreenDemo` (`Sources/NextcloudShowcase/Showcase.swift:586`) is the
reference composition for the first three rows, and its own comment asks for exactly what
we are building: the same thing as a real `NavigationSplitView` column.

## Accessibility is not optional here

`NCAccessibilityLabel` is a **non-optional** argument on the components that take one.
Unlabelled construction does not compile. Decorative icons take `.decorative`; everything
else takes `.content(…)` or `.text(…)`. This is a library design decision and it is a good
one — do not fight it, and do not reach for `.decorative` to silence the compiler.

## Avatar loading

The library forbids `AsyncImage` by lint rule, because it uses `URLSession.shared` and
Nextcloud's avatar endpoints need authentication. Components take a loader instead. Ours
reads the mirror first, per the invariant in
[../architecture/overview.md](../architecture/overview.md):

```swift
func avatarLoader(for address: String) -> @Sendable () async throws -> Image {
    { [store] in
        if let image = try await store.avatar(for: address) { return image }   // mirror
        return try await avatarFetcher.fetchAndStore(address)                   // then network
    }
}
```

`NCAvatar` draws coloured initials when the loader throws, so a 404 needs no special case —
but record it in `avatar.missing` so the client stops asking every launch.

## Gaps: what the library does not give us

The running list with full context is
[../feedback/library-feedback.md](../feedback/library-feedback.md). Summarised here because
it changes what workstreams have to build.

### Missing icons

The catalogue has 91 Material Design Icons. A mail client's chrome needs roughly ten it
does not have:

| Needed for | MDI name |
| --- | --- |
| Inbox | `inbox` |
| Sent | `send` |
| Drafts | `file-document-outline` |
| Archive action and folder | `archive-arrow-down-outline` |
| Attachment indicator | `paperclip` |
| Mark unread | `email-open-outline` |
| Refresh / syncing | `sync` |
| Tags | `tag-outline` |
| Answered indicator | `reply` |
| Snooze (v1.1) | `alarm` |

Present and usable already: `email`, `folder`/`folderOutline`, `star`/`starOutline`,
`delete`/`deleteOutline`/`trashCanOutline`, `alertOctagonOutline` (junk), `magnify`,
`clockOutline`, `download`/`trayArrowDown`, `openInNew`, `dotsHorizontal`, `chevron*`.

Until the catalogue grows, WS-13 uses SF Symbols for the missing ten behind one
`MailSymbol` type, so the substitution is in one file and the swap is mechanical. **Do not
scatter `Image(systemName:)` through the views.**

### Components a mail client wants and the library does not have

- **A list row with a leading accessory column** — the unread dot, the attachment clip and
  the star all want a place before the avatar. `NCListItem`'s leading slot holds one view;
  we compose an `HStack` inside it and lose the library's alignment.
- **A message-header block** — sender, recipients, date, and an actions row is a shape
  every mail client has. We build it; the question for the library is whether it is
  general enough to belong there.
- **A toolbar segmented control** for threaded/flat. System `Picker` works; noting it for
  the parity conversation.
- **Empty-state and settings wrappers** are deliberately absent, and the DocC catalogue
  explains what to use instead. Both hold up fine here.

### Things to verify and report

Each of these is a real question the showcase cannot answer, and WS-13 and WS-08 must
record the answer either way:

1. Does `NCListItem` stay smooth in a `List` of 50,000 rows, or does its `HStack` of
   optional slots cost enough to need a cheaper row?
2. Does `.fontWeight(.semibold)` on the row still mark unread correctly when the row is
   also selected and tinted by the brand colour?
3. Do the brand tint and macOS selection highlight fight in a three-column
   `NavigationSplitView`?
4. Does `NCIcon` render MDI glyphs in a signed, sandboxed app build, not only under Xcode
   run? [ADR-0001](../decisions/0001-xcode-project-in-git.md) assumes yes; nobody has
   checked in a release configuration.
5. Is `NCRelativeDateFormatter`'s short form right for a mail list — "3m", "Yesterday",
   "12 Mar" — or does a mail list want its own rules?
