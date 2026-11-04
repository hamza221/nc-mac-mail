<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# NextcloudUI feedback

*`hamza221/nextcloud-swiftui`'s README is waiting for this: "Build a real Mail client
against it, and freeze the API on what that finds."*

Forty-two workstreams built a native macOS Nextcloud Mail client, and then Contacts, against
`NextcloudUI`, and appended what they hit, each without being able to see the others'
entries. WS-15 curated the first fifteen on 2026-09-23. WS-43 curated the v2 workstreams
(WS-16 to WS-42) on 2026-10-04.

Nothing here was invented at curation. Every finding was written by the workstream that hit
it. What curation did was merge the same finding seen twice into one entry that says so,
re-check the call sites and the library claims against the tree as it stands, mark the
entries that later work resolved or corrected, and put the items a maintainer can act on
first. Raw entries are kept verbatim under the curated headings that group them, with their
workstream on every one.

Versions: `NextcloudUI` at [`1e753cb`](https://github.com/hamza221/nextcloud-swiftui), Xcode
26.6 (17F113), Swift 6.3.3, macOS 26.

Entry format. An entry without a call site is an opinion, not evidence:

```markdown
### Short title
**Workstream:** WS-NN · **Component:** `NCThing` · **Severity:** blocker | friction | polish
**Where:** path/to/File.swift:123
What happened. What we did instead. What would have been better.
```

## How to read this

**Part 1** is for the `NextcloudUI` maintainer. It opens with the ranked list of what to
change before freezing the API, across both rounds, and then holds the v1 findings in
WS-15's sections.

**Part 1b** is what the v2 workstreams added, grouped by component and ranked by upstream
value: the components that the most workstreams worked around come first. Where a v2 entry
repeats a v1 finding, the curated heading says so and the v1 entry carries a pointer back.

**Part 2** is everything else this file collected while it was the only append-only place in
the project: this repository's own packages, a proposed shared Nextcloud client kit, GRDB,
SQLite, Foundation, SwiftPM and the Swift toolchain. It is kept because it is true and
somebody will want it, not because a library maintainer needs to read it.

**Part 3** records what each workstream contributed, so "every workstream is represented" is
checkable rather than claimed.

Findings about the Mail server are in [server-findings.md](server-findings.md). Issue text
ready for a human to post is in [upstream-issues.md](upstream-issues.md).

---

# Part 1: NextcloudUI

## What to change before freezing the API

Ranked across v1 and v2 by how many workstreams worked around the same thing, and by
whether the fix changes a signature (and so cannot wait until after the freeze). Draft issue
numbers refer to [upstream-issues.md](upstream-issues.md).

1. **`NCNoteCard` needs an `actions:` slot.** It combines its children into one
   accessibility element, so a control inside it is unreachable to VoiceOver. WS-09 found it
   in v1; in v2 WS-30 (seven message banners), WS-34 (invitation and itinerary cards), WS-38
   (a dismissible settings error) and WS-40 (a form message) each built the same
   card-plus-buttons by hand. Five workstreams, about a dozen call sites. With it: `onDismiss:`
   and a verbatim `String` overload. See "The two accessibility findings" and Part 1b §1.
   Draft L-1, extended.
2. **`NCUserPicker` must let the caller own the results.** It filters a fixed `candidates:`
   list itself. Recipient autocomplete (WS-26), the recipient field (WS-27), delegation
   (WS-28) and adding team members (WS-37) all needed results that arrive later from a
   server or arrive pre-ranked, and none could use the picker. Four workstreams, and the fix
   changes the initialiser. Part 1b §2. Draft L-8.
3. **Take `NCRichContenteditable`.** The roadmap defers a rich editor to v1.1. WS-20 built
   one with no mail types in it, to be upstreamed (ADR-0065). Part 1b §3. Draft L-7, which
   is postable as it stands.
4. **Decide what a consumer can import.** `NextcloudPlatform` (`NCEmojiPalette`,
   `NCPasteboard`) is neither a product nor re-exported: WS-20 imported it anyway and WS-26
   refused to. WS-42's widget extension could not take the theme without the whole UI
   package. Packaging is part of the API. Part 1b §4. Draft L-9.
5. **`NCListItem` gives a mail row too few slots.** v1 asked for an accessory column, which
   manual QA moved to a trailing cluster. v2 adds a footer line (WS-29), a styled subtitle
   (WS-29), a disabled look (WS-33), hover actions and a density (WS-29), an expanded state
   (WS-30), a leading control (WS-36) and depth (WS-37). Part 1b §5. Draft L-2, extended.
6. **`NCChip` is a token, and five workstreams needed a control.** Toggle (WS-32), wrapping
   group (WS-27, WS-35), "+N" collapse (WS-27), progress (WS-27), activation (WS-09, v1).
   Part 1b §6. Draft L-10.
7. **Fifty-seven Material Design Icons.** The app now draws 95 icons and 57 of them resolve
   to an SF Symbol fallback. v1's eleven are still missing. Part 1b §8 has the table in the
   order to generate it. Draft L-3, extended.
8. **Smaller and signature-safe:** a loading and an icon-only button style and an assistant
   role (Part 1b §7), `NCNavigationItem` secondary count, drop target and action form
   (§9), `NCProfileCard` avatar action and selectable lines (§10), the relative date
   cutoff (v1, draft L-4) and v1's four small asks (draft L-5).

One more has already been fixed, and it is the most useful thing in this document.

## The one finding that completed the round trip

### `.treatAllWarnings(as: .error)` made the library unbuildable from Xcode
**Workstream:** WS-00 · **Component:** `Package.swift` · **Severity:** blocker
**Where:** `Package.swift:19` (`sharedSwiftSettings`), every target
**Status: resolved upstream, 2026-09-22.**

Any Xcode project that depended on `NextcloudUI` failed to build before compiling a line of
its own code:

```
error: conflicting options '-warnings-as-errors' and '-suppress-warnings'
error: Conflicting options (in target 'NextcloudDesign' from project 'nextcloud-ui-swift')
** BUILD FAILED **
```

Xcode hands every package target `-suppress-warnings`, so a dependency's warnings stay out
of the consumer's issue navigator. `.treatAllWarnings(as: .error)` produces
`-warnings-as-errors`. swiftc rejects the pair.

What made it a blocker rather than friction was where the override could go.
`xcodebuild SUPPRESS_WARNINGS=NO` on the command line works, because a command-line setting
reaches the synthesised package projects. `SUPPRESS_WARNINGS = NO` in the consumer's
`.xcodeproj` does not, checked at project level, no effect. There was no fix a consumer
could commit, and **Cmd-B in the Xcode GUI could not be made to work at all** while the
setting was in the manifest.

Fixed upstream exactly as WS-00 suggested and merged as
[`1e753cb`](https://github.com/hamza221/nextcloud-swiftui/pull/2). The manifest no longer
sets `.treatAllWarnings(as: .error)`, and the library's `Makefile` and CI pass
`-Xswiftc -warnings-as-errors` instead. SwiftPM applies `-Xswiftc` to the root package's own
targets and not to its dependencies, so the coverage is identical and consumers are
unaffected.

Verified from this side against the merged commit: bare
`xcodebuild -scheme NextcloudMail build`, with no override, succeeds, so the Xcode GUI
builds this project.

**The part worth keeping is why the library's own CI never caught it.** `swift build` never
passes `-suppress-warnings`, and neither does `xcodebuild` when the package is the root. The
flag appears only when the package is a dependency of another project's target, which no job
in the library exercised. **A library cannot catch this class of bug by building itself.**
A CI job that builds a throwaway Xcode app against the package would have caught it on day
one, and would catch the next one.

One loose end left deliberately, to keep the fix to one thing: the library's `REUSE.toml`
still has a `Showcase/**/*.pbxproj` glob with no project behind it
(`REUSE.toml:30`). The moment that project exists, its own build hits this same class of
problem.

## The two accessibility findings pull in opposite directions

Two components, one combining its children and one not, and both are wrong for the case that
met them. Together they are the argument for a stated rule rather than two fixes.

### `NCNoteCard` combines its children, so a control inside it is unreachable to VoiceOver
**Workstream:** WS-09 · **Component:** `NCNoteCard` · **Severity:** blocker
**Where:** `NextcloudMail/Views/Message/BlockedContentBar.swift:19-30`;
`Sources/NextcloudUI/Components/NoteCard/NCNoteCard.swift:88`

`NCNoteCard`'s body ends with `.accessibilityElement(children: .combine)`, which is right for
a banner that only explains. The blocked-content bar is the shape
[rendering.md](../architecture/rendering.md) asks for and it is not that shape: it is a
warning with two buttons, **Show images** and **Always show from this sender**. `.combine`
makes both unreachable. The card reads as one label and the buttons vanish from the rotor.

`NCChip` has the same constraint and solves it by re-surfacing removal as an accessibility
action (`Components/Chip/NCChip.swift:135-141`). `NCNoteCard` has no equivalent, so the bar
puts its buttons outside the card in an enclosing `VStack`. The result is correct and it is
not one card with its actions, which is what the architecture document describes and what
the design wants.

**What would have been better:** an `actions:` slot,
`NCNoteCard(_:title:content:actions:)`, laid out by the component and left outside the
combined element. Failing that, `children: .contain` when the content builder holds anything
focusable. The failed-body state and the phishing card on this same screen want the same
thing, so it is three call sites in one app.

**v2: seen again, five workstreams now.** WS-30 (seven message banners), WS-34 (invitation
and itinerary cards), WS-38 (a dismissible error) and WS-40 (a form message) each worked
around the same `.combine`. The merged entry and the fuller ask are Part 1b §1.

### `NCNavigationItem` does not combine its children, so the caller must
**Workstream:** WS-07 · **Component:** `NCNavigationItem` · **Severity:** friction
**Where:** `NextcloudMail/Views/Sidebar/SidebarView.swift:82`;
`Sources/NextcloudUI/Components/NavigationItem/NCNavigationItem.swift:72`

The sidebar's acceptance criterion is "VoiceOver reads a mailbox row as name plus unread
count". `NCNavigationItem`'s body is a plain `HStack`: the title `Text`, `NCCounterBubble`
and the trailing-actions `Menu` are three separate accessibility elements, with none of the
`.accessibilityElement(children: .combine)` that `NCListItem` already applies
(`ListItem/NCListItem.swift:115`). Left alone, VoiceOver stops on "Inbox" and then again on
"7 unread" instead of once.

Worked around at the call site: `MailboxTreeRowView.label` applies the combine itself. That
is safe here only because a plain mailbox row carries no other focusable content. Its
context menu is a native `.contextMenu`, not a persistent button, so nothing disappears from
the rotor the way `NCNoteCard`'s buttons did. The account header deliberately does not get
the same treatment, because its trailing actions `Menu` needs its own stop, and
`NCNavigationCaption` already leaves its children uncombined, which is the right default for
a component carrying a control.

**What would have been better:** `NCNavigationItem` combining its own children the way
`NCListItem` does when there is no `actions:` closure. `NCNavigationItem<EmptyView>` has
nothing a combine could break, and the common sidebar row (icon, title, count, no menu) is
exactly that shape.

**The rule the pair suggests**, offered rather than asserted: a component should combine
its children when its generic parameters prove it has no focusable content, and should not
when a caller has supplied any. Both of these components get it wrong for one of their two
shapes, and both got it wrong in the direction of their own most common use.

## Missing icons

**Workstreams:** design pass, WS-07, WS-09, WS-12, WS-13 · **Component:** `NCSymbolCatalog`
· **Severity:** friction
**Where:** `NextcloudMail/MailSymbol.swift` (one file, seventeen cases, the whole app's
icon surface); `Sources/NextcloudIcons/NCSymbolCatalog.swift`

The catalogue ships 91 Material Design Icon assets behind 92 named constants (counted at
`1e753cb`). **Eleven of this app's seventeen icons are not among them** and resolve through
`systemFallback` to an SF Symbol.

The design pass predicted ten before any code existed. WS-13 built `MailSymbol` to that
list and needed nine of them. WS-09 added one more. WS-12 added three settings-tab glyphs,
two of which turned out to be in the catalogue already. Nothing else was needed by any of
the five workstreams that draw. That is a useful signal for the roadmap's open question of
which icons to curate next: the floor for a mail client is these eleven on top of the 91.

In the order a mail client hits them:

| MDI name | Drawn for | Fallback used today |
| --- | --- | --- |
| `inbox` | Inbox mailbox, the nothing-selected state | `tray` |
| `send` | Sent mailbox | `paperplane` |
| `paperclip` | Attachment indicator, attachment chips | `paperclip` |
| `email-open-outline` | Mark unread | `envelope.open` |
| `sync` | Syncing, downloading and failed states | `arrow.triangle.2.circlepath` |
| `tag-outline` | Tags | `tag` |
| `reply` | Answered indicator | `arrowshape.turn.up.left` |
| `archive-arrow-down-outline` | Archive action and mailbox | `archivebox` |
| `file-document-outline` | Drafts mailbox | `doc.text` |
| `image-off-outline` | Blocked-content bar | `photo.badge.exclamationmark` |
| `harddisk` | Storage settings tab | `internaldrive` |

`alarm` makes twelve if snooze lands in v1.1. It is not drawn today, so it is listed
separately rather than counted.

**v2:** snooze landed (WS-31) and draws `alarm-snooze`, which is not in the catalogue
either. It is counted in Part 1b §8's table, not here.

Already present and used: `alertOctagonOutline` (junk), `trashCanOutline`, `folderOutline`,
`star`, `cogOutline`, `accountOutline`, plus `email`, `magnify`, `clockOutline`,
`download`/`trayArrowDown`, `openInNew`, `dotsHorizontal` and `chevron*` in components.

Two notes a maintainer would want. `image-off-outline` is the one whose absence is visible
rather than approximate: the blocked-content bar currently leans on `NCNoteCard(.warning)`'s
own alert glyph, which says "warning" rather than "pictures not shown". And the fallback
mechanism itself worked exactly as documented for all eleven, which is why this is friction
and not a blocker.

**v2:** the app now draws 95 icons and 57 are absent, these eleven included. Part 1b §8.

## API friction

### A list row needs an accessory column, and the leading slot holds one view
**Workstreams:** design pass and WS-08, independently · **Component:** `NCListItem` ·
**Severity:** friction
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift:35-46` and `:63-88`;
`Sources/NextcloudUI/Components/ListItem/NCListItem.swift:79`

**Seen twice.** The design pass predicted it from the component's signature before any code
existed. WS-08 hit it building the real row and recorded the shape it forced.

A mail row is `[unread dot | star | attachment clip] [avatar] [sender / subject] [date /
count]`. Three state glyphs, each optional, then the avatar.
`NCListItem(_:subtitle:leading:details:trailing:)` gives the leading slot one view, so the
row builds `HStack { threeFixedSlots; NCAvatar(...) }` inside it and sizes the slots itself
from `theme.metrics.icon.small` and `theme.metrics.spacing.hairline`. Every absent glyph is
a `Color.clear` of that size, because without a fixed width a row with no glyphs puts its
avatar two points left of a row with one, and a list scanned vertically stops lining up.

It works, it is twenty lines, and the twenty lines are the library's alignment
reimplemented by a caller who cannot see the library's spacing decisions.

**What would have been better:** an `accessories:` slot ahead of `leading:`, laid out by the
component at a width it picks from the metric scale. Files wants the same shape for shared,
favourite and locked; Talk wants it for unread and mention markers. Three apps reimplementing
one alignment is the argument for putting it in the library.

Worth reading beside this: `NCNavigationItem`'s two optional slots are exactly right for a
sidebar row, and WS-07 built a three-level mailbox tree with no accessory `HStack` and no
manual width at all. The gap is specific to rows that carry per-item state, not general.

**Update, first manual QA (2026-10-03): the leading column was the wrong place.** Seen in use,
three fixed slots ahead of the avatar were a blank column on nearly every row, pushing avatar
and subject right. The glyphs now go in the `trailing:` slot, drawn only when they apply,
and `leading:` holds just the avatar. That suggests the library request should change: the
missing piece is a *trailing* accessory cluster beside `details:`, not an `accessories:` slot
ahead of `leading:`. The trailing slot works today because the date and count are already
right-aligned, so a variable-width cluster there doesn't break vertical scanning.

**v2:** WS-29, WS-30, WS-33, WS-36 and WS-37 found seven more slots a row wanted. Part 1b
§5.

### `NCListItem` has no initialiser with `details:` and no `leading:`
**Workstream:** WS-09 · **Component:** `NCListItem` · **Severity:** friction
**Where:** `NextcloudMail/Views/Message/MessageThreadStrip.swift:46-62`

The thread strip wants sender, subject and date, and no avatar, because the avatar is
already in the header six points above and repeating it per sibling is noise. The five
initialisers cover every combination except that one, and the source comment says why: an
unlabelled trailing closure would match two overloads. So the strip draws an avatar it did
not want, and says so in a comment.

**What would have been better:** the labelled form the library's own comment already
suggests, `NCListItem(_:subtitle:details:)`. The ambiguity argument does not apply once the
argument is labelled, which is the case here.

### The short relative date is wrong for a mail list past about a week
**Workstream:** WS-08 · **Component:** `NCRelativeDateFormatter`, `NCListItemDetails` ·
**Severity:** friction
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift:47`;
`Sources/NextcloudUI/Components/ListItemDetails/NCListItemDetails.swift:36-40`

`NCListItemDetails`'s default is `NCRelativeDateFormatter(width: .short, ignoresSeconds:
true)`, which is `Date.RelativeFormatStyle(presentation: .named, unitsStyle:
.abbreviated)`. Measured output, `en_US`:

| Age | Rendered |
| --- | --- |
| 3 minutes | `3 min. ago` |
| 2 hours | `2 hr. ago` |
| 1 day | `yesterday` |
| 5 days | `5 days ago` |
| 9 days | `last wk.` |
| 40 days | `last mo.` |
| 280 days | `9 mo. ago` |

The first four are right. The rest are not what a mail list shows. Every mail client
switches to an absolute date past about a week, and `presentation: .named` loses information
doing the opposite: two messages three weeks apart both read `last mo.`, so the column that
orders the list stops ordering it. `9 mo. ago` is also longer than `12 Mar` in a column that
is 280 points wide in total.

The escape hatch does not escape. `NCListItemDetails(date:unreadCount:formatter:)` takes an
`NCRelativeDateFormatter`, and that type has `width`, `ignoresSeconds` and `locale`
(`NextcloudDesign/Formatting/NCRelativeDateFormatter.swift:40-46`). There is no way to say
"relative under a week, absolute over it", so a caller who wants mail rules cannot use
`NCListItemDetails` at all. WS-08 kept the library's default rather than fork the row,
because a row that draws its own date is a row that has lost the component.

**What would have been better:** a `cutoff: Duration?` on `NCRelativeDateFormatter`, past
which it formats absolutely, `.dateTime.day().month(.abbreviated)` within the year and
`.year()` beyond it. Talk wants the same rule for a conversation list. Failing that, a
`formatter:` parameter on `NCListItemDetails` typed as `some FormatStyle<Date, String>`, so
a caller can supply anything.

### `NCChip` inside a `Button` loses the chip's own pointer and hit target
**Workstream:** WS-09 · **Component:** `NCChip` · **Severity:** polish
**Where:** `NextcloudMail/Views/Message/MessageAttachmentsView.swift:40-43`

An attachment chip is a control: clicking it saves or previews the file. `NCChip` takes
`onRemove:` and nothing else (`Components/Chip/NCChip.swift:36-42`), so the chip goes inside
a `Button` with `.buttonStyle(.plain)` and the app supplies the label and the tooltip.

**What would have been better:** the `action:` parameter `NCUserBubble` already has
(`Components/UserBubble/NCUserBubble.swift:50`). An activatable chip would make the
attachment row three lines shorter and would take its pointer style and hit target from the
library rather than from the caller remembering.

**v2:** one of five `NCChip` asks now. Part 1b §6.

### `NCHighlight` matches a substring, and a full-text index matches terms
**Workstream:** WS-11 · **Component:** `NCHighlight`, `NCHighlightText` · **Severity:**
friction
**Where:** `Sources/NextcloudUI/Components/Highlight/NCHighlight.swift:24`;
this app's terms are built in
`Packages/NCMailStore/Sources/NCMailStore/Search/FTS5MatchExpression.swift:32-34`

`NCHighlight.ranges(in:matching:)` trims the query and looks for that whole string inside
the text. That is right for filtering a list of names, which is what the component was
written for. It disagrees with a full-text index as soon as the query has two words in it.

`hedgehog census` against this app's index is `"hedgehog"* AND "census"*`: two terms, either
order, anywhere in the message. A row matching it can have "hedgehog" in the subject and
"census" forty words into the preview, and `NCHighlight` marks neither, because the literal
string "hedgehog census" does not appear. The reader sees a result with nothing marked and
no clue why it is a result.

**What would help:** an overload taking the terms rather than the query,
`NCHighlight.ranges(in: text, matchingAny: ["hedgehog", "census"])` with a matching
`NCHighlightText(_:matchingAny:)`, so a caller that has already split the query hands the
pieces over instead of re-joining them into something that cannot match. Prefix semantics
come free, because each term is already matched as a substring and a term is its own prefix.

Everything else about the component is right, and the good parts are listed under "Things
that worked". Not wired into the shipped app yet, for the ownership reason in
[ADR-0057](../decisions/0057-search-borrows-the-message-list.md): the row that would call it
belongs to WS-08.

### `NCColorTokens` has no colour for text that should recede
**Workstream:** WS-10 · **Component:** `NCColorTokens` · **Severity:** minor
**Where:** `NextcloudMail/Actions/MoveDestinationList.swift:50`;
`NextcloudDesign/Tokens/NCColorTokens.swift:32-65`

The "No folders match." line in the move popover wants the colour a Nextcloud client uses
for secondary text, the web's `--color-text-maxcontrast`. `NCColorTokens` has `primary`,
`primaryHover`, `primarySurface`, `onPrimary`, `onPrimarySurface`, the four status families,
`favorite`, `highlight`, `userStatus` and `assistant`, and nothing for muted text.

The fallback is SwiftUI's `.secondary`, which is correct on macOS and is not a hard-coded
colour, but it means one string in a Nextcloud-themed popover is coloured by the system
rather than by the theme. Every empty state, caption and timestamp in this app wants the
same token.

### `NCTheme.metrics` has no group for a window's layout
**Workstream:** WS-13 · **Component:** `NCTheme.metrics` · **Severity:** minor

Recorded, and not a request to add one. `NavigationSplitView`'s three column breakpoints
are the window's shape rather than a spacing token, so they live in the app as a private
`ColumnWidth` enum, and the project's "no hard-coded metrics" rule reads them as literals in
a file it cannot tell apart from a padding. If `NCTheme.metrics` ever grows a `layout`
group, a column's min, ideal and max is the first thing that belongs in it.

### `NCKeyboardShortcut` has no collision check
**Workstream:** WS-10 · **Component:** `NCKeyboardShortcut` · **Severity:** polish
**Where:** `NextcloudMailTests/Actions/TriageCommandsTests.swift:16`

A note rather than a request. A table of thirteen shortcuts wants to assert that no two of
them are the same key. The test that does it here compares rendered strings, because that
was shorter than making the type's `Hashable` conformance do it. It already is `Hashable`,
so a `Set` check is available to any caller who thinks of it. A documented "put them in a
`Set` and compare counts" line would be enough.

## Composition gaps

### There is no message-header block
**Workstreams:** design pass and WS-09, independently · **Severity:** polish
**Where:** `NextcloudMail/Views/Message/MessageHeaderView.swift`, about 90 lines

**Seen twice**, and both times with the same conclusion. Sender, recipients, date and an
actions row is a shape every mail client has, and the app builds it from `NCUserBubble`,
`NCChip` and `Text`. The two decisions inside it are the kind a library should settle once:
where recipients collapse (this app collapses past three) and what the "+3" control looks
like.

Whether it generalises is the open question. Talk has a message header, Files has a file
header, and if the answer is that they are three different shapes then the right outcome is
for the library to say so rather than to grow a component nobody else fits.

### What the library should not grow, confirmed by building against it

Four cases where the answer was "the library is right to be absent", recorded because the
question will come up when the API is frozen.

- **No search field.** `.searchable` puts the field in the window's toolbar where macOS
  users look for it, and brings `.searchScopes`, the clear button, Escape-to-clear and
  `.searchFocused` with it. None of that is reachable from a component, because the modifier
  needs the navigation container above it. A component would be a worse field in the wrong
  place. (WS-11, `NextcloudMail/Views/Search/SearchableMessageList.swift`)
- **No `WKWebView` anything.** The whole of `NextcloudMail/WebView/**` is app-specific: the
  scheme, the allowlist, the content rule list, the rewrite. The library not reaching for it
  is correct. (WS-09)
- **No `NCEmptyContent` or `NCSettingsSection`.** `ContentUnavailableView` and
  `Form(.grouped)` are what this app uses, and the DocC notes explaining why are the right
  kind of documentation. Held up across a three-tab settings pane with a
  destructive-confirmation flow on every tab. (design pass, WS-12)
- **No `children:` parameter on `NCNavigationItem`.** Its doc comment says nesting is
  `DisclosureGroup`'s job and declines the parameter for that reason. The decision holds up
  in a real three-level mailbox tree. (WS-07)

One that is smaller: a **toolbar segmented control** for threaded versus flat. The system
`Picker` works. Noted for the parity conversation and nothing more.

## Things that worked

A feedback document that only complains is not evidence.

- **The loader closure instead of `AsyncImage`.** `load: (@Sendable () async throws ->
  Image)?` is the right shape, and the obvious alternative of taking a URL would have been
  unusable here. This app must never let a view reach the network, so the picture comes out
  of the local mirror. A closure lets the caller decide where the bytes come from, and `nil`
  is a first-class "do not try". Wiring both call sites was one line each once
  `MailStore.avatar(for:)` existed. (`NCAvatar`, `NCUserBubble`, store-DAO pass)
- **`NCAvatar`'s fallback contract.** The component draws coloured initials when the loader
  throws, so "no row yet" and "the server answered 404" need no branch at the call site,
  even though they are different facts the fetcher has to tell apart.
- **`NCAvatar`'s cache key includes the diameter** (`Components/Avatar/NCAvatar.swift:135`).
  A mail client draws the same sender at two sizes on one screen, and a key that ignored the
  size would hand one of them the other's bitmap. Invisible until it is wrong.
- **Non-optional `NCAccessibilityLabel`.** Unlabelled construction does not compile, so the
  app cannot accumulate unlabelled controls the way it otherwise would.
- **`.ncTheme(.nextcloud)` at a scene root is one line and it works.** Three columns wear
  the brand colour from a single modifier on the `WindowGroup` content plus
  `@Environment(\.ncTheme)` in the column view. No setup, no injection, no `@StateObject`.
  `NCDynamicColor` conforming to `ShapeStyle` means `.foregroundStyle(theme.colors.primary)`
  composes with no unwrapping. Reassignment recolours the running app, one line after the
  capabilities call. (WS-00, `NextcloudMail/App/NextcloudMailApp.swift`)
- **`NCCounterBubble(count: 0)` draws nothing.** The thread badge is wanted on a thread of
  three and not on a thread of one, and that is
  `count: row.threadCount > 1 ? row.threadCount : 0` rather than an `if` in a view builder
  (`MessageListRow.swift:51`). `NCListItemDetails` collapsing to zero width on a nil date
  and a zero count has the same shape and the same payoff.
- **`NCNavigationItem` composes inside `DisclosureGroup` with nothing to fight.** One icon
  and one count is exactly its two optional slots, so `MailboxTreeRowView` is the component
  used as a `DisclosureGroup` label with nothing built around it. (WS-07)
- **`NCKeyboardShortcut` gives the shortcut table one source.** One value renders as `⌘⇧F`
  and hands `.keyboardShortcut` a `KeyEquivalent`, so the key in the tooltip, the key in the
  menu bar and the key in the shortcut window come from the same `TriageAction.shortcut` and
  cannot drift. `accessibilityDescription(for:)` giving "Command Shift F" is the part that
  would have been forgotten per call site, because the glyphs read as punctuation to
  VoiceOver. (WS-10, `NextcloudMail/Actions/TriageAction.swift:83`)
- **`NCButtonStyle`, `NCNoteCard` and `NCProgressStyle` covered a login screen exactly.** A
  server field, a Continue button, a waiting state and an error banner, with no workaround
  and no custom view. `.ncAccessibilityLabel(.text(...))` labelled the plain `TextField` and
  `ProgressView` that are not library components, which the component map did not call out
  and which worked like the library's own controls. (WS-01,
  `NextcloudMail/Views/Login/LoginView.swift:36`)
- **`NCNoteCard(.info)` inside a system `Form`.** The "local copies only" and sort-order
  explanations slotted into a grouped settings pane with no custom banner and no fighting
  over the grouped background, headers, footers or separators. (WS-12,
  `NextcloudMail/Views/Settings/StorageSettingsView.swift:99`)
- **`NCHighlight`'s split between matching and drawing.** `attributed(_:matching:background:)`
  being separate from the view is what lets matching be tested without SwiftUI. Its
  diacritic folding agrees with the schema's `remove_diacritics 2` without either side
  knowing about the other, and an empty query yielding no ranges is what "highlight as you
  type" needs before the first character.
- **The `MailScreenDemo` in the showcase** is a useful reference composition. It is what the
  sidebar and list briefs pointed at.

## Performance

Everything measured, with the caveat that matters attached to each number.

### `NCListItem` was never asked to be 50,000 rows
**Workstream:** WS-08 · **Component:** `NCListItem` · **Severity:** none
**Where:** `NextcloudMailTests/MessageList/MessageListPerformanceTests.swift:60`

The list is a window over the database, so the largest array `ForEach` ever sees in this app
is 60 rows on selection and 2,580 after twenty-one scroll extensions, never 50,000. At a
real 50,000-row mailbox, selection to rows assigned is **1.8 ms flat and 2.3 ms threaded**,
and extending the window is **3.5 ms**. That is the database and the projection, with no
view in it.

So the question of whether the component's `HStack` of optional slots needs a cheaper row
does not arise at the counts this app builds.

**What was not measured:** SwiftUI drawing those rows and scrolling them at 60 fps. That
needs a window, and there was no GUI in the environment these workstreams ran in. No trace
exists and none is implied.

### The icon bundle survives a signed, sandboxed Release build
**Workstream:** WS-13 · **Component:** `NCIcon.rendersBundledAssets` · **Severity:** none

`xcodebuild -configuration Release SUPPRESS_WARNINGS=NO build` produces a signed, hardened
`NextcloudMail.app` (`codesign -dv` reports `flags=0x10002(adhoc,runtime)`), and its
`nextcloud-ui-swift_NextcloudIcons.bundle/Contents/Resources/Assets.car` still carries every
generated symbol. `assetutil --info` lists 1,566 `"Name"` entries in that one catalogue,
including the four `MailSymbol` cases that resolve to a bundled asset rather than an SF
Symbol. [ADR-0001](../decisions/0001-xcode-project-in-git.md)'s assumption holds for Release
as well as Debug. Evidence from the build product, not from a screenshot: nothing was run
under an opened window.

## Open questions

The six questions the design pass wrote down before implementation, with what the
implementation answered. The two that remain open need eyes on a running window, which no
workstream had.

| # | Question | Status |
| --- | --- | --- |
| 1 | `NCListItem` at 50,000 rows | **Answered** (WS-08). The question does not arise: the list is a window over the database. Rendering and scroll smoothness remain unmeasured. |
| 2 | Does `.fontWeight(.semibold)` still read as unread when the row is selected and tinted? | **Open.** Needs a window. |
| 3 | Is `.ncTheme` setting `.tint` globally right for a mail client, or is `NCAccentPolicy.brandSurfacesOnly` the better default? | **Open**, with a provisional yes. |
| 4 | Do MDI glyphs survive a signed, sandboxed Release build? | **Answered: yes** (WS-13). See "Performance". |
| 5 | Is `NCRelativeDateFormatter`'s short form right for a mail list? | **Answered: no, past about a week** (WS-08). See "The short relative date is wrong for a mail list past about a week". |
| 6 | Does `NCAvatar`'s loader compose with a database-backed cache? | **Answered: yes** (store-DAO pass). See "Things that worked". |

**Question 2 in detail.** What can be said from the source is that the two do not compete
for one property: `NCListItem` sets `.font(.body)` with no explicit weight, with a comment
saying that is so a caller's `.fontWeight` on the whole row wins, and `List` draws selection
as a background fill. Whether semibold reads as heavier against a saturated brand fill is a
contrast question and needs eyes.

**Question 3 in detail.** Nothing in the app shell fought the brand tint driving selection
and focus, and the default `.instance` policy was kept with no evidence against it. But the
shell was three placeholder columns when that was checked, and the sidebar is the column
with the densest selection surface: a `List` several levels deep, nested in
`DisclosureGroup`s. It is the strongest test of this question and it has not been run.

## Not a library gap, recorded where it was found

### The brand colour assumes one instance, and multi-account has no rule for two
**Workstream:** WS-13 · **Severity:** friction
**Where:** `NextcloudMail/App/AppSession.swift`, `refreshTheme()`

[S-09](../product/user-stories.md) and `ui-components.md`'s theme section both write as if
there is one server. The app supports multiple accounts, each with its own mailbox tree, and
nothing in the product specification says whose brand colour wins when two accounts live on
different Nextcloud instances with different colours. `AppSession` picks the first account
in a stable (server, login name) sort, which is deterministic and arbitrary rather than a
considered answer.

Still unanswered at curation: `docs/product/ux-spec.md` has no rule for it. This is a
product question, not a `NextcloudUI` gap, which is why it is recorded here rather than
filed against the library.

### A disabled `.buttonStyle(.icon)` control cannot show its tooltip
**Workstream:** WS-10 · **Component:** `NCButtonStyle.icon` · **Severity:** none

Not the library's fault: a disabled AppKit control does not track the pointer, so `.help` on
a greyed-out button never appears. Recorded because
[ui-components.md](../reference/ui-components.md) recommends `NCButtonStyle.icon` "with
`.help` tooltips carrying the shortcut" for the toolbar, and that advice is silently wrong
for the disabled state. `accessibilityHint` still reaches VoiceOver.
[ADR-0050](../decisions/0050-an-unavailable-action-says-why-in-the-menu.md) has what this
app does instead.

### A SwiftUI `Menu` cannot hold a text field, and the specification asked for one
**Workstream:** WS-10 · **Severity:** none

Nothing for `NextcloudUI` to fix. Recorded because the next person to read "`Menu` with a
filter field" in `ux-spec.md` will start where this workstream started.
[ADR-0052](../decisions/0052-move-is-a-popover-because-a-menu-cannot-hold-a-field.md).

### The coverage footer is a `Text` and did not want a component
**Workstream:** WS-11 · **Component:** `NCNoteCard` · **Severity:** none
**Where:** `NextcloudMail/Views/Search/SearchModel.swift:150`

"Searching 31,204 of 48,902 downloaded messages." is one caption-sized line under the list.
`NCNoteCard` was the nearest component and is too loud for it: a card with a border is for
something the reader should stop at, and this is a footnote they should absorb without
stopping. A plain `Text` with `theme.metrics.spacing` was right, and nothing was bent.

### No generic icon exists for a settings tab, by design
**Workstream:** WS-12 · **Component:** `MailSymbol` · **Severity:** none

Not a `NextcloudUI` gap: the catalogue is Nextcloud- and mail-specific on purpose. The three
settings tabs wanted a gear, a person and a disk glyph. Two of the three turned out to be in
the catalogue (`cogOutline`, `accountOutline`) and the third is `harddisk`, now in the
missing-icons table.

---

# Part 1b: NextcloudUI, what v2 added

Twenty-seven v2 workstreams (WS-16 to WS-42), sixteen of which draw UI. Each section below
starts with the curated finding, which says which workstreams hit it, which call sites
carry the workaround, and what would be better. The raw entries follow, verbatim, with
their workstream. Sections are in order of upstream value: how many workstreams worked
around the same thing, and whether the fix changes a signature.

Claims re-checked at curation against `NextcloudUI` `1e753cb` and against the app's tree
as it stands. One was corrected (§8: eight of WS-20's twenty-three "missing" editor glyphs
are in the catalogue). The rest stand.

## 1. `NCNoteCard`: actions, dismissal and runtime text

**Workstreams:** WS-30, WS-34, WS-38, WS-40, extending WS-09's v1 blocker · **Severity:**
blocker for accessibility, friction otherwise
**Where:** `NextcloudMail/Views/Message/MessageBanners.swift` (seven banners),
`NextcloudMail/Views/Calendar/CalendarCards.swift` (`InvitationCard`, `ItineraryCards`),
`NextcloudMail/Views/Settings/App/AppSettingsComponents.swift` (`SettingsErrorCard`),
`NextcloudMail/Views/AccountSetup/AccountSetupSheet.swift` (`feedbackSection`), and v1's
`NextcloudMail/Views/Message/BlockedContentBar.swift`;
`Sources/NextcloudUI/Components/NoteCard/NCNoteCard.swift:88` (still
`.accessibilityElement(children: .combine)` at `1e753cb`)

The most-worked-around component in the project. In v1 one workstream hit it at one call
site. In v2 four more hit it independently, and every one of them put the buttons beside or
under the card in a hand-built stack, so about a dozen layouts in one app now "do not quite
agree" (WS-30's words). Three asks, in order:

1. **`actions:`**, laid out by the card and left outside the combined element. Covers
   blocked content, phishing, read receipts, follow-up, translation, S/MIME, PGP,
   invitations and itineraries.
2. **`onDismiss:`**, a close button the card owns. WS-38's inline error has to go away once
   read and carries a hand-placed "Dismiss" button; WS-40's form message wants the same.
3. **A verbatim `String` message.** `message:` is a `LocalizedStringResource`, so server
   text (phishing reasons, a follow-up date, a language name) needs the content-builder form
   and one `Text` per line.

WS-40's lighter one-line form message (`NCFormMessage(kind:)` with an announcement on change)
is a separate, smaller component. It is filed here because it would share the roles and the
dismissal.

### `NCNoteCard` still swallows its controls
**Workstream:** WS-30 · **Component:** `NCNoteCard` · **Severity:** friction
**Where:** NextcloudMail/Views/Message/MessageBanners.swift
Seven banners (phishing, read receipt, follow-up, translation, remote content, S/MIME, PGP)
each want one or two buttons. `NCNoteCard` ends with `.accessibilityElement(children: .combine)`,
so a button inside it is unreachable to VoiceOver (WS-09's entry), and every banner puts its
buttons in an `HStack` beside or under the card instead — seven hand-built layouts that do
not quite agree. Needed: an `actions:` slot that stays outside the combined element.

### A note card with actions
**Workstream:** WS-34 · **Component:** `NCNoteCard` · **Severity:** friction
**Where:** NextcloudMail/Views/Calendar/CalendarCards.swift (`InvitationCard`, `ItineraryCards`)
The invitation card's Accept/Decline/Tentatively accept, and each itinerary's "Import into
calendar" menu, sit beside the card, because the card combines its children for VoiceOver
(already filed by WS-09). Two workstreams now build the same card-plus-row-of-buttons by hand.
An `actions:` slot that stays outside the combined element would cover both.

### `NCNoteCard` takes `LocalizedStringResource`, not runtime text
**Workstream:** WS-30 · **Component:** `NCNoteCard` · **Severity:** friction
**Where:** MessageBanners.swift (phishing reasons, follow-up date, translation language)
`message:` is a `LocalizedStringResource`, so a banner whose text is interpolated or comes from
the server needs the content-builder form and a `Text` per line. A `String` overload (verbatim)
would cover server-supplied text without a builder.

### No inline dismissible error
**Workstream:** WS-38 · **Component:** `NCNoteCard` · **Severity:** gap
**Where:** AppSettingsComponents.swift (`SettingsErrorCard`)
The web shows "Could not update preference" as a toast. Settings shows it inline under the
controls, and it has to go away once read. `NCNoteCard` has no close action, so the card
carries a hand-placed "Dismiss" button. An `onDismiss:` parameter would fix that, and
WS-40's form message would use it too.

### No inline form-feedback line
**Workstream:** WS-40 · **Component:** `NCNoteCard` · **Severity:** gap
**Where:** AccountSetupSheet.swift (`feedbackSection`)
The form's one-line error/instruction ("IMAP username or password is wrong", "Account
created. Please follow the pop-up instructions…") is too light for an `NCNoteCard` and
changes as the flow runs. It is a coloured `Text` with `.updatesFrequently`; an
`NCFormMessage(kind:)` with the error/info colours and a VoiceOver announcement on change
would make the pattern uniform with Settings' status lines (WS-38/39).

## 2. `NCUserPicker`: the caller must own the results

**Workstreams:** WS-26, WS-27, WS-28, WS-37 (and WS-38's text-block sharing, by WS-37's
account) · **Severity:** blocker for reuse
**Where:** `NextcloudMail/Views/People/RecipientSuggestionProvider.swift`,
`NextcloudMail/Views/Composer/RecipientField.swift`,
`NextcloudMail/Views/Sidebar/DelegationSheet.swift`,
`NextcloudMail/Views/Contacts/Teams/TeamDetailView.swift` (`AddTeamMemberSheet`);
`Sources/NextcloudUI/Components/UserPicker/NCUserPicker.swift:63,74`

**Seen four times, and no v2 screen that picks people uses the picker.** `NCUserPicker`
takes a `candidates:` pool and filters it by substring itself. Every v2 caller had results
that arrive after the keystroke (a server search, a sharees route at about a third of a
second per term) or arrive already ranked by rules the picker does not know (recency,
frequency, identities last; ADR-0072). Delegation fell back to a user-id `TextField`, team
members to a `TextField` over a `List` of `NCListItem`s, and the composer built its own
chip field on `NCChip`.

Two shapes would cover all four, and both change the public initialiser, which is why this
ranks second:

- **A search-driven picker:** `results: [Candidate]` supplied by the caller (or
  `search: (String) async -> [Candidate]`), no internal filtering, and a pending state while
  results are fetched. Delegation, team members and share sheets.
- **A token field:** `NCTokenField(tokens:text:suggestions:commit:)`, where the caller owns
  parsing (free-typed and pasted addresses, invalid text left to fix, case-insensitive
  duplicates). Recipient fields. It needs §6's wrapping chip layout.

### `NCUserPicker` cannot be a recipient field
**Workstream:** WS-27 · **Component:** `NCUserPicker` · **Severity:** blocker for reuse
**Where:** NextcloudMail/Views/Composer/RecipientField.swift
A mail recipient field takes free-typed addresses (valid ones become chips, invalid text stays
to be fixed), pasted lists with names, suggestions that arrive while the user types (local,
then server rows merged), and duplicates refused case-insensitively. `NCUserPicker` picks ids
out of a fixed `candidates:` pool shown as a `List`, with its own filtering, so none of that
fits; the composer builds its own field on `NCChip`. Needed: a token-field variant —
`NCTokenField(tokens: Binding<[Token]>, text: Binding<String>, suggestions: [Suggestion],
commit: (String) -> [Token])` — where the caller owns parsing and suggestions.

### `NCUserPicker` filters a fixed list; autocomplete needs a two-phase source
**Workstream:** WS-26 · **Component:** `NCUserPicker`, `NCUserSearch` · **Severity:** friction
**Where:** NextcloudMail/Views/People/RecipientSuggestionProvider.swift
Recipient autocomplete (ADR-0072) yields a local list and then a longer one when the server
supplement lands, ranked by rules `NCUserSearch` does not know (recency, frequency, identities
last). `NCUserPicker` takes `candidates:` and does its own substring filtering, so it cannot
show a pre-ranked, growing list; the provider therefore exposes an `AsyncStream` and leaves the
chip field to the composer. Same request as WS-28's: a search-driven picker variant
(`results: [Candidate]` supplied by the caller, no internal filtering).

### `NCUserPicker` needs candidates nobody can supply yet
**Workstream:** WS-28 · **Component:** `NCUserPicker` · **Severity:** friction
**Where:** NextcloudMail/Views/Sidebar/DelegationSheet.swift
Delegation picks one Nextcloud user. `NCUserPicker` filters a candidate list it is handed,
which suits recipients but not a server-side user search with debounce; the sheet takes a user
ID in a `TextField` instead. A search-driven variant (`search: (String) async -> [Candidate]`)
would fit share sheets and delegation alike.

### `NCUserPicker` cannot search a server
**Workstream:** WS-37 · **Component:** `NCUserPicker` · **Severity:** gap
**Where:** NextcloudMail/Views/Contacts/Teams/TeamDetailView.swift (`AddTeamMemberSheet`)
The picker filters a candidate list it is given. Adding team members needs a search the server
answers (the sharees route, users and groups, a third of a second per term), arriving after
the keystroke. So the sheet is a plain `TextField` over a `List` of `NCListItem`s that the
`sharees` row fills. A picker that takes candidates as a changing binding and shows a pending
state while they are fetched would cover this, the delegation picker (WS-39) and text-block
sharing (WS-38).

## 3. Proposed component: `NCRichContenteditable`

**Workstream:** WS-20 · **Severity:** offer, not gap
**Where:** `NextcloudMail/Editor/**`; [ADR-0065](../decisions/0065-native-rich-text-editor.md),
[ADR-0073](../decisions/0073-editor-canonical-html.md),
[ADR-0074](../decisions/0074-editor-triggers.md); `docs/product/ux-spec.md`, "Composer
editor (WS-20)"

`NextcloudUI`'s roadmap defers a rich-text editor to v1.1. ADR-0065 decided to build one
here that is upstreamable from the start, and WS-20 did: no mail types anywhere, theming
through `.ncTheme`, every control labelled. It has since carried the composer (WS-27), the
per-identity signature editor (WS-39) and the text-block sheet (WS-38, "dropped in
as-is"), so it has three consumers inside one app already.

The proposal, ready to post, is draft **L-7** in [upstream-issues.md](upstream-issues.md).
Two raw entries feed it: the proposal itself and what TextKit 2 did not hand over, which an
upstream design has to know before it starts. The editor's icon needs are in §8 and its
import problem in §4.

### Proposal: upstream this editor as `NCRichContenteditable`
**Workstream:** WS-20 · **Component:** NextcloudUI (missing component) · **Severity:** offer, not gap
**Where:** NextcloudMail/Editor/**
NextcloudUI's ROADMAP defers a rich editor to v1.1; ADR-0065 built one here that is
deliberately upstreamable. What exists: a TextKit 2 `NSTextView` (`ComposerTextView`), an
`@Observable` document (`EditorDocument`) with plain/rich modes, its own
`HTMLSerializer`/`HTMLImporter` over a fixed, canonical tag set (ADR-0073, fixed-point
tested construct by construct), a full toolbar (heading/family/size, B/I/U/S, colours,
sub/sup, image embed, alignment, LTR/RTL, lists, quote, link, remove format,
`NSTextFinder` find/replace, editable source view, undo/redo), a trigger-session API
(`:`/`@`/`!`/`/`, ADR-0074) behind three provider protocols, and a restricted pasteboard
whose HTML path never touches WebKit. No mail types anywhere; theming is `.ncTheme`
tokens; every control is labelled. The one seam to cut for upstreaming: the tokenizer is
the app's `HTMLScanner`/`HTMLEntities` (~270 lines, also mail-free) — it would move into
the library with the editor. macOS-only today (`NSTextView`); the serialiser/importer
halves are AppKit-string code an iOS `UITextView` host could share.

### Where TextKit 2 fell short of §6.5
**Workstream:** WS-20 · **Component:** AppKit (not a library gap) · **Severity:** recorded for the upstream design
Four things the web client's CKEditor does that TextKit 2 does not hand over:

- **Inline image resizing.** No selection handles on `NSTextAttachment`; building them
  means custom hit-testing over `NSTextLayoutManager` fragments. v2 ships without
  interactive resize — `width` survives the round trip and is the serialised unit.
- **Ordered-list numbering is instance-based.** `NSTextList` ordinals count paragraphs
  sharing one list *instance*; splitting a list mid-edit restarts numbering at the split.
  Cosmetic only here, because block identity (and therefore the serialised HTML) lives in
  a custom attribute, not in the text list.
- **HTML on the pasteboard is WebKit's by default.** `NSTextView`'s built-in `.html`
  reading goes through `NSAttributedString(html:)`, which can fetch. There is no reader
  hook to replace; the only safe seam is overriding `readSelection(from:type:)` and never
  calling super for `.html`. Anyone upstreaming an editor must know this one.
- **`performTextFinderAction` wants a `tag`.** No typed API to open the find bar's
  replace interface; the caller fabricates an `NSMenuItem` with
  `NSTextFinder.Action.showReplaceInterface.rawValue`. Works, reads like a workaround.

One stdlib note in the same spirit: `Unicode.Scalar.Properties` exposes `isEmoji` and
`isEmojiPresentation` but not `isExtendedPictographic`, so the emoji-trigger heuristic
(ADR-0074) approximates with presentation-default-or-above-U+238C.

## 4. Packaging: what a consumer can import

**Workstreams:** WS-20, WS-26, WS-42, WS-38 · **Severity:** friction, and an API decision
**Where:** `NextcloudMail/Editor/ComposerTextView.swift:5` (`import NextcloudPlatform`),
`NextcloudMail/Views/People/ContactCardPopover.swift:119-123` (writes `NSPasteboard`
instead), `NextcloudMailWidgets/NextcloudMailWidgets.swift`,
`NextcloudMail/Views/Settings/SettingsScene.swift`; `Package.swift:49-51` (three products:
`NextcloudDesign`, `NextcloudUI`, `NextcloudIcons`) and
`Sources/NextcloudUI/Exports.swift:14,17`

**Two workstreams made opposite choices about the same module, which is the finding.**
`NextcloudPlatform` holds `NCEmojiPalette` and `NCPasteboard`, is not a product, and is not
re-exported by `NextcloudUI`. WS-20 imported it anyway, which compiles only because Xcode
puts every package target's module in the build directory. WS-26 read the same situation
as "unreachable" and wrote `NSPasteboard` directly. Both are reasonable, and an API that
admits both is not frozen.

Two neighbouring asks belong to the same decision:

- **A dependency-free tokens product** (WS-42). A WidgetKit extension will not link the
  whole UI package and its asset catalogues for a few metrics and a brand colour, so the
  widgets use system styles.
- **An `Image` from an `NCSymbol`** (WS-38). `tabItem` takes `Label(_:image:)`, and the
  catalogue hands out a view, so the eleven-tab Settings window has no tab icons.

### `NCEmojiPalette` is not reachable through `NextcloudUI`
**Workstream:** WS-20 · **Component:** NextcloudPlatform / NextcloudUI exports · **Severity:** friction
**Where:** NextcloudMail/Editor/ComposerTextView.swift:5
The brief says "NextcloudUI `NCEmojiPalette`", but the type lives in `NextcloudPlatform`,
which `NextcloudUI` neither re-exports (its `Exports.swift` re-exports only
`NextcloudDesign` and `NextcloudIcons`) nor is declared as a library product in
`Package.swift`. `import NextcloudPlatform` compiles in an Xcode build because every
package target lands in the build directory, but that is an implementation detail, not an
API. Ask: either add `NextcloudPlatform` to the `@_exported` list or promote it to a
product.

### `NCPasteboard` is unreachable from `NextcloudUI`
**Workstream:** WS-26 · **Component:** `NCPasteboard` (`NextcloudPlatform`) · **Severity:** friction
**Where:** NextcloudMail/Views/People/ContactCardPopover.swift (`copy(_:)`)
"Copy address" wanted `NCPasteboard.copy`, but `NextcloudUI` re-exports only
`NextcloudDesign` and `NextcloudIcons`, and the app links only the `NextcloudUI` product, so
the card writes `NSPasteboard` itself. Re-exporting `NextcloudPlatform` (or shipping it as part
of `NextcloudUI`) would let every app copy text the same way.

### WS-42: the widget extension cannot use the theme
**Workstream:** WS-42 · **Component:** `NCTheme` / `ncTheme` · **Severity:** low
**Where:** NextcloudMailWidgets/NextcloudMailWidgets.swift
The widget extension does not link `NextcloudUI`: pulling the package (and its asset
catalogues) into a WidgetKit process for a few spacing tokens was not worth the size, and
`NCTheme` needs a brand colour the widget has no way to read except through the snapshot. So
the widgets use system styles and default stack spacing, no theme tokens. A small,
dependency-free `NextcloudUITokens` product (metrics and the brand colour as plain values)
would let an extension follow the app. `MailSymbol` is likewise app-only, so the widgets draw
no glyphs. Nothing else from `NextcloudUI` was involved: Spotlight, the Share extension and
Services have no UI of their own.

### No settings-window tab metadata
**Workstream:** WS-38 · **Component:** — · **Severity:** friction
**Where:** NextcloudMail/Views/Settings/SettingsScene.swift
The Settings window has eleven tabs. A macOS settings toolbar wants an icon on each tab,
but `MailSymbol` returns a view, not an `Image`, and `tabItem` only takes `Label(_:image:)`.
So the tabs are text-only. If the catalogue exposed an `Image` (or an `NCSymbol` →
`Label` helper), the window could look like a native preferences window.

## 5. `NCListItem`: the slots a mail row still builds

**Workstreams:** WS-29, WS-30, WS-33, WS-36, WS-37, extending the design pass, WS-08 and
WS-09 · **Severity:** friction
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift` (`adornmentLines`,
`subjectLine`, `isCompact`), `NextcloudMail/Views/MessageList/MessageListView.swift`
(`MessageHoverActions`), `NextcloudMail/Views/Files/FilesPicker.swift:167` (the
`.opacity(… ? 1 : 0.5)`), `NextcloudMail/Views/Message/ThreadEnvelopeRow.swift`,
`NextcloudMail/Views/Contacts/AddressBooks/AddressBooksSheet.swift`,
`NextcloudMail/Views/Contacts/Teams/ContactTeamsExtras.swift` (`OrgChartSheet`)

`NCListItem` was the right row for members, sharees, shared items and the org chart
(WS-37), and for the Files picker (WS-33). Where it fell short, it fell short the same way
each time: the row has title, subtitle, one leading view, details and a trailing view, and a
mail or contacts row wants more places to put things. The worst of the seven is the footer:
WS-29 indents a second block by `metrics.avatar.medium + metrics.spacing.standard` to line
up with the text column, which is a guess at the item's internal layout that breaks if the
item changes.

The asks, most valuable first: a `footer:` slot inside the text column; an `isEnabled`-aware
look; a `Text` or `AttributedString` subtitle; `hoverActions:` plus an
`.ncListDensity(.compact)` environment value; a disclosure form with an expanded content
slot (the web's `ThreadEnvelope`); a leading control slot beside `leading:`; and a depth or
outline form with connectors. With v1's trailing accessory cluster, that is eight. Several
could be one generic slot API rather than eight parameters, which is the maintainer's call.

### `NCListItem` has no third line
**Workstream:** WS-29 · **Component:** `NCListItem` · **Severity:** friction
**Where:** NextcloudMail/Views/MessageList/MessageListRow.swift (`adornmentLines`)
A mail row needs sender, subject, then a preview and a chip line (tags, attachments). The item
takes title and subtitle only, so the row stacks a second block under it and indents it by
`metrics.avatar.medium + metrics.spacing.standard` to line up with the text column — a guess at
the item's internal layout that breaks if the item changes. A `footer:` slot inside the text
column would remove the guess.

### `NCListItem` subtitles cannot be styled in part
**Workstream:** WS-29 · **Component:** `NCListItem` · **Severity:** friction
**Where:** MessageListRow.swift (`subjectLine`)
The web shows a draft's subject as *Draft:* in italics before the subject. The subtitle is a
`String`, so the prefix is plain text. An `AttributedString` (or `Text`) subtitle overload
would allow it.

### No hover-actions or compact density for list rows
**Workstream:** WS-29 · **Component:** `NCListItem` · **Severity:** friction
**Where:** MessageListView.swift (`MessageHoverActions`), MessageListRow.swift (`isCompact`)
Quick actions on hover are an overlay with a material background and borderless buttons built
in the app; compact mode switches the avatar size by hand. A `hoverActions:` slot and a
`.ncListDensity(.compact)` environment value would make Files, Mail and Talk rows agree.

### No list/browser row with a selection-disabled look
**Workstream:** WS-33 · **Component:** NextcloudUI `NCListItem` · **Severity:** friction
**Where:** `NextcloudMail/Views/Files/FilesPicker.swift`
"Choose a folder" mode lists files dimmed and unselectable. `NCListItem` has no disabled
state, so the picker applies `.opacity(0.5)` itself. An `isEnabled`-aware style (the web
`NcListItem` greys disabled rows with the theme's disabled colour) would remove the magic
number. `NCBreadcrumbs` fitted the picker without changes.

### No collapsed/expanded list row
**Workstream:** WS-30 · **Component:** `NCListItem` · **Severity:** friction
**Where:** ThreadEnvelopeRow.swift, MessageView.swift
Thread mode is a list of collapsed rows around one expanded card. `NCListItem` is the
collapsed row; the expanded state and its disclosure affordance are app-built, as is the
"expand on click, collapse on header click" behaviour. An `NCDisclosureListItem` with an
expanded content slot would make the web's `ThreadEnvelope` pattern a component.

### No list row with a leading switch and trailing actions
**Workstream:** WS-36 · **Component:** — · **Severity:** gap
**Where:** NextcloudMail/Views/Contacts/AddressBooks/AddressBooksSheet.swift
Each address book row is a hand-built switch + name/caption + ⋯ menu (web Contacts'
`AddressBook.vue` row: checkbox, name, actions). The calendar list will need the same row,
with a colour dot as well (WS-34 filed the swatch). An `NCListItem` with `leading:`/`actions:`
slots would cover both.

### No tree or indented list for a hierarchy
**Workstream:** WS-37 · **Component:** — · **Severity:** gap
**Where:** NextcloudMail/Views/Contacts/Teams/ContactTeamsExtras.swift (`OrgChartSheet`)
The organisation chart is a `List` of `NCListItem`s with leading padding of
`spacing.loose × depth`. That reads, but it draws no connectors and does not collapse. Web
Contacts uses d3-org-chart. A library outline row (depth, disclosure, connector lines) would
also serve nested mailboxes.

## 6. `NCChip`: five workstreams needed a control, not a token

**Workstreams:** WS-27, WS-32, WS-35, extending WS-09 · **Severity:** friction
**Where:** `NextcloudMail/Views/Search/SearchFilterBar.swift` (`SearchToggleChip`),
`NextcloudMail/Views/Composer/RecipientField.swift` (`FlowLayout`, `hiddenCount`),
`NextcloudMail/Views/Composer/ComposerParts.swift` (`AttachmentStrip`),
`NextcloudMail/Views/Contacts/ContactDetailView.swift` (`ContactFlowLayout`);
`Sources/NextcloudUI/Components/Chip/NCChip.swift:36`

**The wrapping layout was built twice,** by WS-27 (`FlowLayout`) and WS-35
(`ContactFlowLayout`), which is the strongest single item here: an `NCChipGroup` that wraps
with the theme's spacing, with an optional limit and a "+N more" that both the composer and
the message header now hand-roll. Then: a selectable form (`NCChip(_:isOn:)`, owning the role
swap and the `.isSelected` trait), a progress and failed state for uploads, and v1's
`action:`.

### No wrapping layout for chips
**Workstream:** WS-27 · **Component:** `NCChip` / `NCUserPicker` · **Severity:** friction
**Where:** RecipientField.swift (`FlowLayout`), ComposerParts.swift (`AttachmentStrip`)
`NCUserPicker`'s chips scroll on one line ("revisit when a screen needs twenty recipients").
A recipient field and an attachments strip both need chips that wrap, so the app has its own
`FlowLayout`. An `NCChipFlow` (or a public flow `Layout`) would serve Mail, Deck labels and
Talk participants alike.

### No wrapping chip group
**Workstream:** WS-35 · **Component:** `NCChip` · **Severity:** gap
**Where:** ContactDetailView.swift (`ContactFlowLayout`), ContactEditor.swift
Contact groups are chips that wrap across lines. `NCChip` is a single chip; the wrapping
`Layout` is app-built. Recipient fields (WS-27) and tag rows want the same: an `NCChipGroup`
that wraps with the theme's spacing would make one implementation of this.

### `NCChip` has no "+N more" collapse
**Workstream:** WS-27 · **Component:** `NCChip` · **Severity:** friction
**Where:** RecipientField.swift (`hiddenCount`)
§6.4 collapses long recipient lists to "+N"; the message view does the same past three. Both
hand-roll a borderless button after the chips. A collapsing chip-list component with a limit
would make the two agree on wording and accessibility.

### `NCChip` has no selectable (toggle) form
**Workstream:** WS-32 · **Component:** NextcloudUI `NCChip` · **Severity:** friction
**Where:** `NextcloudMail/Views/Search/SearchFilterBar.swift` (`SearchToggleChip`)
The search filter chips (Has attachment, Unread, To me) are on/off filters, the web client's
`NcChip` with a selected state. `NCChip` is a display token only — a role, a tint and an
optional remove button — so the app wraps it in a plain `Button`, swaps `.primary`/`.neutral`
by hand and adds the `.isSelected` trait itself. An `NCChip(_:isOn:)` (or an
`NCFilterChip`) owning the role swap, the selected trait and keyboard focus would replace the
wrapper.

### `NCChip` cannot show progress
**Workstream:** WS-27 · **Component:** `NCChip` · **Severity:** friction
**Where:** ComposerParts.swift (`AttachmentStrip`)
An attachment chip wants a progress bar while it uploads and a failed state (red, faded). The
chip has a `role` and a leading view only; progress would need a trailing slot or a
`progress: Double?` parameter.

## 7. Buttons: loading, icon-only, assistant

**Workstreams:** WS-40, WS-38, WS-39 (by WS-38's account), WS-30 · **Severity:** friction
**Where:** `NextcloudMail/Views/AccountSetup/AccountSetupSheet.swift` (`buttons`),
`NextcloudMail/Views/Settings/App/AppSettingsComponents.swift:66` (`SettingsIconButton`,
used across the settings tabs), `NextcloudMail/Views/Message/MessageReplyArea.swift`,
`NextcloudMail/Views/Message/MessageHeaderView.swift`

Three small styles, none of which changes an existing signature. `NCButton(isLoading:label:)`
with a stable minimum width; an `NCIconButton(symbol:label:action:)` that carries its own
label and tooltip; and an assistant role. The last is cheaper than it looks:
`NCColorTokens` already has `assistant: NCAssistantColors`
(`NextcloudDesign/Tokens/NCColorTokens.swift:65`), so only `NCButtonStyle.assistant` and
`NCChip.Role.assistant` are missing.

The library's `docs/ROADMAP.md` already defers the assistant components to v1.1, waiting for
Liquid Glass conventions for AI affordances. v2's evidence for that decision: the two a mail
client reaches first are a badge ("Contains AI content") and a button style (smart
replies), and both are small.

### No button with an in-progress label
**Workstream:** WS-40 · **Component:** — (button styles) · **Severity:** friction
**Where:** NextcloudMail/Views/AccountSetup/AccountSetupSheet.swift (`buttons`)
The web's account form shows progress *on* the submit button: a spinner and a label that
walks "Looking up configuration" → "Checking mail host connectivity" → "Testing
authentication" → "Loading account". The library has no button state for that, so the
sheet hand-builds an `HStack` of `ProgressView` + `Text` inside a plain `Button`, and the
button resizes as the label changes. An `NCButton(isLoading:label:)` with a stable minimum
width would serve every long-running submit (account setup, S/MIME import, filter save).

### No icon-only row button
**Workstream:** WS-38 · **Component:** `NCIcon` / buttons · **Severity:** friction
**Where:** NextcloudMail/Views/Settings/App/AppSettingsComponents.swift (`SettingsIconButton`)
Every settings list (trusted senders, internal addresses, text blocks, shares, S/MIME
certificates) ends rows in a remove/edit icon. The library has no borderless icon button
that carries its own accessibility label and tooltip, so the app wraps `Button` +
`MailSymbol.view` + `.help` + `.accessibilityLabel`. WS-39 built the same thing for quick
actions. An `NCIconButton(symbol:label:action:)` would make one.

### No assistant/AI styling
**Workstream:** WS-30 · **Component:** `NCButtonStyle`, `NCChip` · **Severity:** gap
**Where:** MessageReplyArea.swift (smart replies), MessageHeaderView.swift ("Contains AI content")
The web client styles smart replies and the AI badge with the Assistant gradient. The library
has no assistant role, so the app uses `.secondary` buttons and a `.primary` chip with a
sparkles glyph. An `NCButtonStyle.assistant` and `NCChip.Role.assistant` would make AI output
recognisable the same way in every Nextcloud app.

## 8. Missing icons, v2

**Workstreams:** WS-20, WS-31, WS-33, and every v2 workstream that draws · **Component:**
`NCSymbolCatalog` · **Severity:** friction
**Where:** `NextcloudMail/MailSymbol.swift` (95 cases, the whole app's icon surface);
`Sources/NextcloudIcons/NCSymbolCatalog.swift`

Counted at curation from `MailSymbol.swift` against the catalogue at `1e753cb`: the app
draws **95** icons. 26 use a catalogue constant; 69 name an asset; 12 of those 69 names are
in the catalogue after all and resolve to the MDI glyph; **57 resolve to an SF Symbol
fallback**. v1 counted eleven of seventeen. Those eleven are still absent and are in v1's
table above. The forty-six v2 added are below, grouped by what draws them.

**A correction at curation.** WS-20's entry says all twenty-three editor glyphs are absent.
Eight are in the catalogue: `format-bold`, `format-italic`, `format-underline`,
`format-align-left`, `format-align-center`, `format-align-right`, `link-variant` and `undo`
(for example `NCSymbolCatalog.swift:159` `formatBold`, `:274` `undo`). Because `NCIcon`
resolves any bundled asset name, those eight already draw the MDI glyph; fifteen editor
glyphs are absent. The same is true of `chevron-right`, `dots-horizontal`, `open-in-new`
and `checkbox-marked-circle-outline`, which `MailSymbol` names by string where it could use
the constant. That is app-side tidying, not a library gap.

| Group | MDI name | Drawn for | Fallback used today |
| --- | --- | --- | --- |
| Editor (WS-20) | `format-strikethrough-variant` | Strikethrough | `strikethrough` |
|  | `format-subscript` | Subscript | `textformat.subscript` |
|  | `format-superscript` | Superscript | `textformat.superscript` |
|  | `image-plus` | Insert image | `photo.badge.plus` |
|  | `format-align-justify` | Justify | `text.justify` |
|  | `format-pilcrow-arrow-right` | Left to right | `arrow.right.to.line` |
|  | `format-pilcrow-arrow-left` | Right to left | `arrow.left.to.line` |
|  | `format-list-bulleted` | Bulleted list | `list.bullet` |
|  | `format-list-numbered` | Numbered list | `list.number` |
|  | `format-quote-close` | Block quote | `text.quote` |
|  | `format-clear` | Remove formatting | `eraser` |
|  | `find-replace` | Find and replace | `magnifyingglass` |
|  | `code-tags` | Source | `chevron.left.forwardslash.chevron.right` |
|  | `redo` | Redo | `arrow.uturn.forward` |
|  | `format-text` | Formatting | `textformat` |
| Message actions and banners (WS-30, WS-31) | `reply-all` | Reply all | `arrowshape.turn.up.left.2` |
|  | `share` | Forward | `arrowshape.turn.up.right` |
|  | `alarm-snooze` | Snooze | `clock.badge` |
|  | `label-variant` | Important | `exclamationmark.circle` |
|  | `printer` | Print | `printer` |
|  | `eye-outline` | Preview | `eye` |
|  | `translate` | Translate | `character.bubble` |
|  | `email-remove-outline` | Unsubscribe | `envelope.badge.minus` |
|  | `email-check-outline` | Read receipt | `envelope.badge` |
|  | `lock-off-outline` | Signature unverified | `lock.slash` |
|  | `creation` | Contains AI content | `sparkles` |
|  | `email-outline` | Forwarded message | `envelope` |
| Mailboxes and navigation (WS-28, WS-29) | `inbox-multiple` | All inboxes | `tray.2` |
|  | `label-variant-outline` | Priority inbox | `bolt.horizontal` |
|  | `inbox-arrow-up` | Outbox | `tray.and.arrow.up` |
|  | `folder-account-outline` | Shared folder | `folder.badge.person.crop` |
|  | `chevron-left` | Back | `chevron.left` |
|  | `view-split-vertical` | View options | `rectangle.split.3x1` |
| Status (WS-27, WS-38, WS-40) | `alert-outline` | Warning | `exclamationmark.triangle` |
|  | `information-outline` | Information | `info.circle` |
| Files (WS-33) | `file-outline` | File | `doc` |
|  | `file-image-outline` | Image | `photo` |
|  | `refresh` | Reload | `arrow.clockwise` |
|  | `cloud-outline` | From Files | `icloud` |
| Contacts, calendar and teams (WS-34, WS-35, WS-37, WS-38) | `domain` | Domain | `globe` |
|  | `certificate-outline` | Certificate | `checkmark.seal` |
|  | `cloud-download-outline` | Picture from social network | `icloud.and.arrow.down` |
|  | `airplane` | Flight | `airplane` |
|  | `train` | Train | `tram` |
|  | `sitemap-outline` | Organization chart | `point.3.connected.trianglepath.dotted` |
|  | `logout` | Leave team | `rectangle.portrait.and.arrow.right` |

WS-33's ask is broader than its three glyphs: the MDI file-type set (file, image, pdf,
document, spreadsheet, audio, video, archive), so every Files surface can match the web.
`alarm-snooze` replaces v1's `alarm` placeholder now that snooze exists (WS-31).

### Missing icons: the whole format-* family
**Workstream:** WS-20 · **Component:** NextcloudIcons · **Severity:** polish
**Where:** NextcloudMail/MailSymbol.swift:95
Twenty-three editor glyphs (`format-bold`, `format-italic`, `format-underline`,
`format-strikethrough-variant`, `format-subscript`, `format-superscript`, `image-plus`,
`format-align-left/center/right/justify`, `format-pilcrow-arrow-left/right`,
`format-list-bulleted`, `format-list-numbered`, `format-quote-close`, `link-variant`,
`format-clear`, `find-replace`, `code-tags`, `undo`, `redo`, `format-text`) are all absent
from the catalogue, so the toolbar runs entirely on SF fallbacks. The `MailSymbol`
pattern absorbed that in one file, which is the pattern working as designed — but an
editor component upstreamed as `NCRichContenteditable` will need the MDI set.

### No file-type icons in the symbol catalogue
**Workstream:** WS-33 · **Component:** NextcloudUI `NCSymbol` · **Severity:** friction
**Where:** `NextcloudMail/MailSymbol.swift` (`.file`, `.imageFile`, `.reload`)
A Files browser needs a generic file glyph, an image-file glyph and a refresh glyph. The
catalogue has `folder`/`folderOutline`/`folderUpload` but no `file-outline`,
`file-image-outline` or `refresh`, so the app names those MDI assets and lives on the SF
Symbol fallback. Bundling the MDI file-type set (file, image, pdf, document, spreadsheet,
audio, video, archive) would let every Files surface match the web client's icons.

## 9. `NCNavigationItem` and `NCNavigationCaption`

**Workstreams:** WS-28, WS-36, WS-37 · **Severity:** friction and polish
**Where:** `NextcloudMail/Views/Sidebar/SidebarView.swift` (`MailboxTreeRowView.label`,
`.dropDestination … isTargeted`), `NextcloudMail/Views/Contacts/AddressBooks/AddressBooksSectionHeader.swift`,
`NextcloudMail/Views/Contacts/Teams/TeamsSidebarRows.swift`

v1 found the item composes inside `DisclosureGroup` perfectly and WS-37 drew team member
counts with it unchanged. Four additions, all additive: `secondaryCount:` drawn "3 (5)" in
one pill (on `NCCounterBubble` too); `isTargeted:` for drag-and-drop; an action form for
"New team…" rows that sit among selectable ones; and an `accessory:` on the section
caption.

### `NCNavigationItem` takes one count; Nextcloud's sidebar shows "3 (5)"
**Workstream:** WS-28 · **Component:** `NCNavigationItem`, `NCCounterBubble` · **Severity:** friction
**Where:** NextcloudMail/Views/Sidebar/SidebarView.swift (`MailboxTreeRowView.label`)
The web navigation draws a folder's own unread and, in brackets, its subfolders' total in one
`NcCounterBubble`. `NCNavigationItem(count: Int)` and `NCCounterBubble(count: Int)` take one
integer, so the row puts a second `NCCounterBubble(role: .outlined)` after the item, outside
its layout. A `secondaryCount:` on both (drawn "3 (5)" inside one pill) would keep the row
one component.

### `NCNavigationItem` has no drop-target state
**Workstream:** WS-28 · **Component:** `NCNavigationItem` · **Severity:** polish
**Where:** NextcloudMail/Views/Sidebar/SidebarView.swift (`.dropDestination … isTargeted`)
Message drags onto folders need the targeted highlight; the row paints its own
`theme.colors.primarySurface` rounded background behind the item. An `isTargeted` (or
`highlighted`) parameter would make every sidebar drop target look the same.

### A sidebar row that is an action, not a selection
**Workstream:** WS-37 · **Component:** `NCNavigationItem` · **Severity:** friction
**Where:** NextcloudMail/Views/Contacts/Teams/TeamsSidebarRows.swift
"New team…" sits among selectable rows (web Contacts' `+ Create team` in the navigation). It is
an `NCNavigationItem` inside a `Button` with `.buttonStyle(.plain)` and no tag, so the
`List(selection:)` leaves it alone; the hover and focus look are whatever that combination
gives. An action variant of `NCNavigationItem` would match the web.

### A sidebar section caption has no accessory slot
**Workstream:** WS-36 · **Component:** `NCNavigationCaption` · **Severity:** friction
**Where:** NextcloudMail/Views/Contacts/AddressBooks/AddressBooksSectionHeader.swift
Web Contacts puts its "Contacts settings" and "Import" entries in the navigation footer, and
its add-book "+" next to the section. The caption takes only a title, so the ⋯ menu is a
hand-built `HStack` (caption, `Spacer`, a borderless `Menu` with `.menuIndicator(.hidden)`),
and the spacing, hover and hit area are whatever SwiftUI gives. An `NCNavigationCaption(_:accessory:)`
(or a `trailing` menu slot) would match the web's section actions.

## 10. `NCProfileCard`

**Workstreams:** WS-26, WS-35 · **Severity:** friction and polish
**Where:** `NextcloudMail/Views/People/ContactCardPopover.swift`,
`NextcloudMail/Views/Contacts/ContactDetailView.swift`

The card fitted the contact popover "exactly" (WS-26) and the contact detail page. Two
additive asks: `.textSelection(.enabled)` on the secondary lines, and an `avatarMenu:` or
`onAvatarTap` slot so "change picture" sits on the picture.

### `NCProfileCard` secondary lines cannot be selected
**Workstream:** WS-26 · **Component:** `NCProfileCard` · **Severity:** polish
**Where:** NextcloudMail/Views/People/ContactCardPopover.swift
The card fits the §5.11 contact popover exactly, but its `secondaryLines` are plain `Text`, so
the address under the name cannot be selected and the card needs its own "Copy address"
button. A `selectableSecondaryLines` flag (`.textSelection(.enabled)`) would remove it.

### `NCProfileCard`'s avatar takes no action
**Workstream:** WS-35 · **Component:** `NCProfileCard`, `NCAvatar` · **Severity:** friction
**Where:** NextcloudMail/Views/Contacts/ContactDetailView.swift
Web Contacts opens the picture menu (upload, full size, download, social, remove) from the
avatar itself. The card's avatar is not interactive and has no menu or `onTap` slot, so the
picture actions sit in the card's ⋯ menu instead, one level further from where users look.
An `avatarMenu:` (or `onAvatarTap`) slot would let every app put "change picture" where the
picture is.

## 11. Components that do not exist yet

**Workstreams:** WS-34, WS-35, WS-36 · **Severity:** gap

Four shapes Contacts and Calendar need and the library has no answer to. Ranked: the
property row (Contacts, Calendar event details and Mail's message details all want it), the
colour swatch (every calendar list), the image cropper (Contacts and the profile settings),
and a comparison row for merge (one screen, and WS-36 says a documented pattern would do).

Two of these meet the library's v1.1 list (`docs/ROADMAP.md`, "Deferred to v1.1"). The
deferred `NCColorPickerPalette` is the input half of the swatch; the display swatch is
smaller and could land first. And the deferred `NCFilePicker` now has a working reference:
WS-33's `NextcloudMail/Views/Files/FilesPicker.swift`, a Files browser over cached listings
with a choose-a-folder mode, whose only library entries were the icons in §8 and the
disabled row in §5.

### No labelled property row
**Workstream:** WS-35 · **Component:** — · **Severity:** gap
**Where:** ContactDetailView.swift (`ContactPropertiesView`)
A contact card is "Email · Work — lorelai@…" rows with an action (mailto, tel, link). The
library has list items and navigation items but no label/value property row, so the card is
a hand-built `Grid`. An `NCPropertyRow(label:value:action:)` fits Contacts, Calendar event
details and Mail's message details alike.

### No calendar choice or colour swatch
**Workstream:** WS-34 · **Component:** — · **Severity:** gap
**Where:** NextcloudMail/Views/Calendar/MessageCalendarCards.swift (`CalendarPicker`)
"Save to", "Import into" and the two sheets choose a calendar. The web shows each one with
its colour dot (`CalendarPickerOption.vue`). The library has no picker row with a leading
swatch, so the app shows names only. An `NCColorSwatch(hex:)` (the colour comes as `#RRGGBB`
from CalDAV), or a picker option view, would make this parity.

### No square image cropper
**Workstream:** WS-35 · **Component:** — · **Severity:** gap
**Where:** ContactPhoto.swift (`ContactPhotoCropSheet`)
Web Contacts and the Nextcloud profile settings both crop pictures square before upload. The
app built a drag-and-zoom crop sheet; a library `NCImageCropper(aspectRatio:)` would give every
Nextcloud app the same behaviour and output size.

### A two-way choice row for merge
**Workstream:** WS-36 · **Component:** — · **Severity:** gap
**Where:** NextcloudMail/Views/Contacts/AddressBooks/ContactMergeSheet.swift
Merge is a stack of "this card's value / that card's value" radio groups and per-value
checkboxes. Plain `Picker(.radioGroup)` and `Toggle(.checkbox)` in a grouped `Form` work, but
they do not show which card a value comes from the way the web's merge dialog columns do. A
library comparison row would help, as would a documented pattern for one.

## 12. Things that worked, v2

Six view workstreams wrote one down. The pattern across them: `Form` with
`.formStyle(.grouped)` laid out every settings, setup and merge screen with no custom
layout (WS-36, WS-38, WS-40); `NCNoteCard`'s four roles mapped straight onto states the web
already has (WS-34's iMIP states, WS-38 and WS-40's feedback), so the asks in §1 are about
its children, not its design; `NCButtonStyle.icon`, `theme.metrics` and `NCIcon`'s mandatory
label carried a 25-control toolbar (WS-20). Also, from reports rather than entries:
`NCBreadcrumbs` fitted the Files picker (WS-33) and the move picker (WS-31) with no changes.

### Things that worked (WS-20)
`NCButtonStyle.icon` carried a 25-control toolbar with no fighting; `theme.metrics`
had every spacing the toolbar needed; `NCIcon`'s mandatory label meant the VoiceOver
acceptance row was free; SwiftUI `ColorPicker` was the right colour control and needed no
library replacement.

### Things that worked (WS-40)
`NCNoteCard(.info)` for the provider hints and the "contact your administrator" state;
`Form` + `.formStyle(.grouped)` gives the web dialog's IMAP/SMTP groups without custom
layout.

### Things that worked (WS-38)
`Form` + `.formStyle(.grouped)` covered every tab without custom layout. `NCNoteCard(.error)`
and `(.success)` gave the S/MIME import and text-block share feedback the web's toast
wording. The composer's `ComposerEditor` dropped into the text block sheet as-is.

### Things that worked (WS-34)
`NCNoteCard`'s roles map straight onto the web's iMIP states (`.info` invited, `.success`
accepted, `.warning` declined, `.error` cancelled), and its `title:` takes the web's sentences
as written. `.buttonStyle(.secondary)`/`.tertiary` matched the web's button order.

### Things that worked (WS-36)
`Form` + `.formStyle(.grouped)` laid out the merge choices and the settings sheet without
custom spacing. `MailSymbol.more`/`.group`/`.account` covered every icon, so no new
`MailSymbol` cases were needed.

### Things that worked (WS-37)
`NCNavigationItem`'s count drew the member count for each team row, and `NCListItem` with an
`NCAvatar` leading slot was right for members, sharees, shared items and the chart. Three
`MailSymbol` cases were appended (`team`, `orgChart`, `leaveTeam`).

## 13. Not a library gap, recorded where it was found

### WS-41: nothing new from NextcloudUI
**Workstream:** WS-41 · **Component:** — · **Severity:** none
**Where:** NextcloudMail/Notifications/
WS-41 draws no UI of its own. Banners are Notification Center's and the badge is
`NSApp.dockTile.badgeLabel`, so `NextcloudUI` was not involved and has no gap here. The one
friction was outside the library: a SwiftUI `App` has no hook that hands `openWindow` /
`openComposer` to code that is not a view. `MailNotifierHooks` captures them from the main
window's environment, and a banner's Reply that arrives before that (the banner launched the
app) waits for it.

---

# Part 2: not NextcloudUI

These entries landed in this file because it was the project's only append-only place. They
are kept in full, grouped by who could act on them.

## `NCMailStore`, this repository's own package

One shape runs through all of these. `MailStore.read` and `MailStore.write` became internal
in [ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md), which is right, and
it means a gap in the DAOs is a gap the caller cannot route around. WS-04 needed two, WS-05
needed four, WS-06 needed five and could not ship without them. The store's write surface
was designed around the backfill, and sync writes different columns.

### `NCMailStore` had the queue's table and no queries over it
**Workstream:** WS-06 · **Component:** `MailStore` · **Severity:** blocker
**Status: resolved**, by the store-DAO pass
([ADR-0045](../decisions/0045-the-store-grows-the-queue-dao-and-the-readers.md)).

`pendingOperation` and `PendingOperationRecord` existed and nothing read or wrote them, so
`applyLocally` and the queue insert could not be put in one transaction from `NCMailSync` at
all, and that transaction is the whole of ADR-0005. WS-06 declared an `OperationStoring`
protocol and conformed `MailStore` to it in the test target, where `@testable` reaches
`read`/`write`. The consequence that mattered: nothing outside `NCMailSync` could construct
a `MutationQueue`, so the queue was unreachable from the app.

`Queries/MailStore+Operations.swift` now holds `enqueue(_:applying:)`,
`pendingOperations(accountId:)`, `markInFlight(ids:)`,
`reschedule(ids:attempts:nextAttemptAt:lastError:)`, `finish(ids:applying:)` and
`threadMessages(accountId:rootId:)`. `OperationStoring` is deleted.

### Four DAO gaps the sync engine worked around, three of which still stand
**Workstream:** WS-05 · **Component:** `NCMailStore` · **Severity:** friction
**Where:** `SyncScheduler+Mailbox.swift`, `SyncScheduler.swift`

WS-05 listed four. The first is half closed and three stand, re-checked at curation against
the store's current public surface.

1. **Reading `pendingOperation` inside the sync write transaction.** Half closed.
   `pendingOperations(accountId:)` exists, so the read is a DAO call now, but
   `upsert(envelopes:preservingPendingOperationsFor:)` still does not exist, so the engine
   still reads the queue either side of the write and repairs afterwards.
   [ADR-0037](../decisions/0037-the-queue-is-read-twice-around-the-sync-write.md) names the
   replacement and is still the live arrangement.
2. **No `setMailboxStats(unread:total:mailboxId:)`.** A sync response's `stats` is two
   integers, and writing them means rebuilding a fifteen-column `MailboxWrite` from the
   `MailboxRecord` that was just read and calling `upsert(mailboxes:)`. Safe, because the
   write omits every mirror-bookkeeping column by design, and fifteen columns to move two.
3. **No `recordSyncSuccess(mailboxId:at:)`.** `recordSyncFailure(mailboxId:message:)` exists
   with no counterpart. `setEnvelopeCursor(_:complete:mailboxId:lastSyncAt:)` is the only
   DAO that stamps `lastSyncAt` and clears `syncFailureCount` and `lastSyncError`, which is
   exactly what a successful sync means, so the engine calls it with the mailbox's existing
   cursor and completion flag passed straight back in. It works, and a reader is entitled to
   think sync is moving stage 1's cursor, which it must never do.
4. **`account.lastDeepReconcileAt` has no setter.** The column is on `AccountRecord` and
   nothing writes it, so the weekly timer lives in `meta` under
   `sync.lastDeepReconcile.<accountId>`. Two homes for one fact, cheap to fix now and
   confusing in a year.

### A caller outside the package cannot put two store calls in one transaction
**Workstream:** WS-04 · **Component:** `NCMailStore` · **Severity:** friction
**Where:** `MailStore.upsert(envelopes:)`,
`MailStore.setEnvelopeCursor(_:complete:mailboxId:lastSyncAt:)`

[local-mirror.md](../architecture/local-mirror.md) asked stage 1 for one transaction over a
page and its cursor. `upsert(envelopes:)` opens its own, and the pieces it uses,
`SearchIndexWriter` and `EnvelopeWrite.indexedPeople`, are internal to the package, so a
caller cannot reproduce the page write inside its own transaction without reimplementing the
address rewrite and the FTS row from outside the module that owns them.

Resolved by ordering rather than by a new method
([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)): envelopes commit first, the
cursor second, and a crash between them re-reads one page.
`upsert(envelopes:cursor:complete:mailboxId:)` remains a small addition if the store's owner
would rather have it than the ordering argument. The general form still stands, and it is
the same wall ADR-0037 hit from the other side.

### `mailbox.lastPrimedAt` had no DAO
**Workstream:** WS-04 · **Component:** `NCMailStore` · **Severity:** friction
**Status: resolved.** `MailStore.setLastPrimedAt(_:mailboxId:)` exists and
`MirrorCoordinator.storePrimed` uses it.

Not a courtesy: once `MailStore.read`/`write` became internal, the raw-SQL escape hatch
stage 0 had been using was gone and the DAO had to exist for the coordinator to compile.

### `MailClient` never reports how many bytes came back
**Workstream:** WS-05 · **Component:** `NCMailNet` · **Severity:** friction
**Where:** `SyncMetrics.envelopeBytesDown`

[sync-engine.md](../architecture/sync-engine.md) asks the instrumentation for "bytes down".
`MailClient.get` hands back a decoded value, and `bytes(_:)`, the one verb that returns
`Data`, is typed `Endpoint<Data>` and so is unavailable for a JSON endpoint. The counter
sums the `rawJSON` each envelope carries, which is the payload and not the response, and its
documentation has to say so. A `(value, byteCount)` overload, or a transport-level meter
`MailClient` could be handed, would make the number the one the document asks for. The live
measurement test works around it with its own `MailTransport` wrapper, which is fine for a
test and not something the app can do.

## `NCMailTestSupport`

### `FakeTransport.fail` cannot say "never succeeds"
**Workstreams:** WS-05 and WS-06, independently · **Component:** `FakeTransport` ·
**Severity:** polish
**Where:** `FakeTransport.swift:72`; three call sites in two packages:
`NCMailSyncTests/SyncSchedulerTests.swift:176`,
`NCMailSyncTests/OperationDrainTests.swift:352`,
`NCMailSyncTests/OperationSyncConflictTests.swift:36`

**Seen twice, and this is the entry where seeing it twice is the finding.** WS-05 recorded
it and asked whether it was a one-off. WS-06 hit it independently and said it is not: "the
network is gone" is the central situation of the offline queue, and it is spelled
`fail(route, times: 10_000, then: .status(200))`. The doc comment on `fail` tells callers to
write exactly that, so the magic number is documented rather than accidental, and it still
needs a comment at every call site explaining that 10,000 means forever.

Two changes would remove it. A `.always` case, or `times: Int? = nil` meaning forever. And
`fail(route, alwaysWith: URLError(...))`, which would also let a test choose the error:
every failure this fake produces is `MailError.transport(URLError(.networkConnectionLost))`
(`FakeTransport.swift:170`), so a test cannot tell a timeout from a DNS failure.

Not widened by either workstream, because it is WS-14's API. WS-14 appended no entry of its
own to this file; this is the gap its consumers recorded on its behalf.

### `NCMailTestSupport` could not be used by the tests it was created for
**Workstream:** WS-02 · **Component:** `Packages/NCMailTestSupport/Package.swift` ·
**Severity:** blocker at the time
**Status: resolved** by WS-14
([ADR-0026](../decisions/0026-fixtures-through-a-dependency-free-target.md), superseding
[ADR-0022](../decisions/0022-fixtures-by-path-not-bundle.md) for `NCMailCoreTests` and
`NCMailStoreTests`).

The package depended on `NCMailCore`, `NCMailNet` and `NCMailStore`, so none of their test
targets could depend on it: SwiftPM rejects the cycle. `Bundle.module`, which
[testing-strategy.md](../delivery/testing-strategy.md) tells every package to load fixtures
through, was reachable only from `NCMailTestSupportTests`. WS-02 worked around it by
resolving the fixture directory from `#filePath`.

WS-14 took the second of the two fixes WS-02 named: a dependency-free `NCMailFixtures`
target inside the package, vending the recorded bytes, with `FakeTransport` and
`MailStoreFixtures` above it in a second product. `NCMailNetTests` still takes the full
product and still lives with ADR-0022's arrangement, which is why that record is superseded
in part rather than in whole.

## GRDB

### `ValueObservation` over a `WITHOUT ROWID` table never fires
**Workstream:** WS-03 · **Severity:** trap
**Where:** [ADR-0025](../decisions/0025-rowid-tables-for-anything-observed.md)

`ValueObservation` is built on `sqlite3_update_hook`, and
[SQLite does not call that hook for `WITHOUT ROWID` tables](https://www.sqlite.org/c3ref/update_hook.html).
An observation of such a table delivers its first value and then waits forever. No error, no
warning, no timeout. The first symptom was a test that hung. Four tables in `schema.sql`
were `WITHOUT ROWID` and three of them were things a view would want to watch.

**Worth an upstream report.** GRDB could detect this when an observation starts, where it
already resolves the tracked region against the schema, and trap with "cannot observe
WITHOUT ROWID table `avatar`". The information is all there and the failure mode is silence.

### `ValueObservation.start` has two overloads and picks the wrong one
**Workstream:** wave-2 fixes · **Severity:** friction
**Where:** `MailStore.swift`, `startTracking(_:in:scheduling:onError:onChange:)`

GRDB 7 declares `start(in:scheduling:onError:onChange:)` twice: a `nonisolated` one taking
`some ValueObservationScheduler`, and a `@MainActor` one taking
`some ValueObservationMainActorScheduler`. `.mainActor` satisfies both, and passing it from
a `nonisolated` context selects the `@MainActor` overload and fails with "call to main
actor-isolated instance method in a synchronous nonisolated context", which reads as a
concurrency mistake rather than an overload-resolution one. The workaround is a helper whose
scheduler parameter is an opaque `some ValueObservationScheduler`, which the main-actor
overload cannot match.

### GRDB's names are not fully re-exported
**Workstream:** WS-06 · **Severity:** friction

`Records/**` and `Projections/**` use `public import GRDB`, and ADR-0034 notes that GRDB's
names stay visible to a module that imports `NCMailStore`. Partly.
`Int.fetchOne(_:sql:)` resolves through the re-export; `Database`, `StatementArguments` and
`DatabaseValueConvertible` named as types do not. A test file that wrote a store DAO needed
`import GRDB` for a module its package does not declare as a dependency, which compiled only
because SwiftPM had GRDB in the search path. That is a coincidence rather than a contract,
and one more reason the DAO belongs in `NCMailStore` where the import is declared. Moot
since ADR-0045 moved those DAOs.

### The system SQLite folds ASCII only, and nothing says so
**Workstream:** security-audit fixes · **Severity:** trap
**Where:** [ADR-0104](../decisions/0104-one-fold-for-the-avatar-key.md), `MailStore+Avatars.swift`

GRDB links the system `libsqlite3`, which is built without ICU, so `lower()` and
`COLLATE NOCASE` fold `A`–`Z` and nothing else. Swift's `lowercased()` folds all of Unicode.
The avatar table was written with one and queried with the other: a sender `Ö@…` was never
found again and the fetcher asked about it forever, and a sender `\u{212A}evin@…` (Kelvin
sign) overwrote `kevin@`'s photo. Neither GRDB nor SQLite warns, and every ASCII fixture
passes. The fix is to let SQLite compute every key it will later compare.

**Worth a line in GRDB's documentation** next to its collation helpers: the bundled fold is
ASCII-only unless the app ships its own SQLite with ICU.

## SQLite

### FTS5 virtual tables reject `ON CONFLICT`, so there is no upsert
**Workstream:** WS-03 · **Severity:** friction
**Where:** `SearchIndexWriter`

`messageSearch` is written from two places: an envelope supplies subject, preview and
people, a body supplies the text. Neither may clobber the other's columns, and a virtual
table has no `INSERT ... ON CONFLICT DO UPDATE` to express that. The shape that works is
`UPDATE ...; if changesCount == 0 { INSERT ... }`, which reads like a mistake until you know
why. There is a comment in the file saying so.

### An index helps only if the predicate lets the planner choose it
**Workstream:** WS-03 · **Severity:** none

The threaded list took 196 ms for its first fifty rows out of fifty thousand, against 0.5 ms
for the flat one. Nothing was missing: `idxMessageThread` existed and the plan used it for
two of the three subqueries. The unread count was written
`count(*) ... WHERE mailboxId = ? AND threadRootId = ? AND isSeen = 0`, and that third term
made `idxMessageMailboxSeen` look attractive, so the planner took it, matching every unread
message in the mailbox and filtering by thread afterwards. Rewriting it as
`sum(CASE WHEN isSeen THEN 0 ELSE 1 END)` over the same two-column predicate took it to
0.8 ms.

The lesson generalises past this query. `EXPLAIN QUERY PLAN` saying "uses an index" is not
the assertion worth making. Which index, and over how many rows, is.

### Deleted FTS5 rows stay in the file until a `rebuild`
**Workstream:** security-audit fixes · **Severity:** trap
**Where:** [ADR-0105](../decisions/0105-removed-mail-leaves-the-search-index.md), `MailStore.vacuum()`

Deleting from an FTS5 table writes a delete marker; the postings stay in
`messageSearch_data` until a merge drops them, and `VACUUM` does not merge. Removed mail
stayed readable in the file's bytes after "Remove Local Copies". `optimize` did not drop
them either in a single-segment index; only `rebuild` or the table's `secure-delete` option
did, and `secure-delete` multiplied ordinary write costs by four to thirty on mirror-shaped
data. Apple's SQLite also defaults `PRAGMA secure_delete` to `FAST`, which another build
would not, so the purge migration sets it explicitly.

## WebKit

### The context-menu item identifiers are not in any public header
**Workstream:** security-audit fixes · **Severity:** friction
**Where:** [ADR-0107](../decisions/0107-the-message-web-view-strips-loading-menu-items.md), `MessageBodyWKWebView.strip(_:)`

"Download Linked File" starts a load that neither the navigation delegate nor the content
rule list sees, so the message view removes it in `willOpenMenu(_:with:)`. The
`WKMenuItemIdentifier…` constants that name it are exported by `WebKit.tbd` and declared in
no SDK header, so Swift matches on their string values. A rename in WebKit would quietly
stop the match, and no test in this repository can notice.

## The Swift toolchain

### `@testable import` reaches a module's types but not its file-scope functions
**Workstream:** WS-06 · **Severity:** friction

From `NCMailSyncTests`, `@testable import NCMailStore` resolved `MailStore.write`,
`PendingOperationRecord` and every record type, and did not resolve
`databaseQuestionMarks(count:)`, an internal file-scope function in the same module. The
compiler did not say "cannot find". It said `error: failed to produce diagnostic for
expression; please submit a bug report`, which cost twenty minutes of bisecting a thirty-line
method to find out which symbol it meant. **Worth an upstream report against the toolchain.**
Three lines were copied rather than fight it.

### `swift format` disagrees with `#expect` about trailing closures
**Workstream:** WS-02 · **Severity:** polish

`#expect(list.allSatisfy(\.isSelectable))` does not compile: the macro expands the key path
into a position where the `rethrows` overload is selected and the call is not marked `try`.
`#expect(list.allSatisfy { $0.isSelectable })` is fine. Worth knowing before the third time
it happens. `Testing.Tag` also collides with this project's `Tag` model, so a test that names
the model in a type annotation has to qualify it as `NCMailCore.Tag`.

## v2: this repository's own packages

Six entries from the v2 engines, recorded for this repository's maintainers. One was fixed
in place (the multistatus parser); the rest stand at curation.

### Three sync actors have no `stop()`
**Workstream:** WS-25 · **Component:** NCMailSync · **Severity:** friction
**Where:** `MirrorCoordinator`, `ServerStateMirror`, `ServerResultFetcher`
Sign-out has to stop everything, and these three only stop when told they are offline
(`apply(conditions:)` with `isOffline`), which is what `AccountEngine`'s `EnginePart`
conformances do (ADR-0084). It works because a stopped instance is discarded, but it leaves
`ServerStateMirror`'s launch refresh uncancellable: a refresh in flight at sign-out finishes
its writes. A real `stop()` on each, cancelling the run in flight, would replace the stand-in.

### Settings models decode, but cannot re-encode
**Workstream:** WS-21 · **Component:** NCMailCore · **Severity:** friction
Most settings routes decode into plain `Decodable` models rather than `RawBacked`, so their
rows keep `rawJSON = "{}"` and the mirror re-states `MailFilter`/`OutOfOfficeState`/
certificate info as small `Encodable` mirrors to fill its JSON columns. `RawBacked` on the
settings list endpoints would make ADR-0020 hold for v2 tables too.

### The multistatus parser flattened `current-user-privilege-set`
**Workstream:** WS-24 · **Component:** NCMailNet · **Severity:** friction
**Where:** `DAVMultistatusParser`
The parser kept only a property's direct children, so every privilege arrived as a bare
`privilege` element and writability was undecidable (the birthday calendar has no
`oc:read-only`). Fixed in place with Main's approval: `DAVResource.privileges` lifts the name
inside each `privilege`; test `privilegesComeBackFlatFromTheNestedSet`.

### Two store columns triage reads from JSON
**Workstream:** WS-31 (from its report, added at curation) · **Component:** `NCMailStore` ·
**Severity:** polish
**Where:** `NextcloudMail/Actions/MailboxRights.swift` (ACLs parsed from mailbox `rawJSON`
`myAcls`), `NextcloudMail/Actions/TagRules.swift` (default tags inferred from labels
`$label2` to `$label5`)
`TagRecord` stores no `isDefaultTag`, so default tags are inferred from their labels; if a
user can rename or delete a default tag, a column would be more accurate. Mailbox ACLs are
parsed from `rawJSON` on each availability refresh; a column would avoid the parse. Neither
is wrong today.

## v2: `NCMailTestSupport` and the test harness

The v1 entry above said `FakeTransport.fail` could not say "never succeeds". v2's three
entries are the same kind: the fake transport is right, and three of its edges cost a
workstream an hour each.

### `FakeTransport.stall` can miss a request that arrives first
**Workstream:** WS-21 · **Component:** NCMailTestSupport · **Severity:** friction
**Where:** `FakeTransport.stall(_:)`
`stall` only catches a request sent *after* the test registered it, and the documented
`async let handle = stall(…)` pattern races the code under test. One WS-21 test hung the
whole suite for 20 minutes when the refresh won the race. `GatedTransport` in
`ServerStateTestSupport.swift` (hold everything matching from construction, `waitForHeld`,
`open`) is deterministic; worth promoting into `NCMailTestSupport`.

### `RequestMatcher` has `&&` but no `||`, and `.path` drops the trailing slash
**Workstream:** WS-24 · **Component:** NCMailTestSupport · **Severity:** papercut
**Where:** `RequestMatcher.path(_:)`
`URL.path` strips the collection's trailing `/`, so `.path("/…/addressbooks/users/user/")`
never matches a DAV collection request; `.pathSuffix` without the slash does. Worth one line
in the matcher's doc comment.

### `.local` servers never resolve inside the app-hosted test runner
**Workstream:** WS-25 · **Component:** test harness · **Severity:** friction
**Where:** `NextcloudMailTests` hosted in `NextcloudMail.app`
`AccountEngineLiveTests` against `http://nextcloud.local` (an `/etc/hosts` entry) times out
in the resolver: the unified log shows `resolver:dns_stall` and then `-1001` four times, while
`curl` from the same shell answers in 0.3 s and the package live tests (`swift test`, not an
app process) reach the same host. Network.framework resolves `.local` through mDNS, which
needs Local Network permission the test host app never gets a prompt for. Resolved in the
dev stack: nginx and `trusted_domains` now also accept `localhost` and `127.0.0.1`, so
app-hosted live tests use `NCMAIL_LIVE_SHELL=http://localhost` (also `TEST_RUNNER_`-prefixed
for xcodebuild); the package tests can keep `nextcloud.local`.

## v2: a shared Nextcloud client kit, proposed

**Workstreams:** WS-16, WS-17, WS-23 · **Severity:** offer, not gap

Three workstreams independently arrived at the same conclusion from three directions:
every Nextcloud Apple client re-types the OCS envelope and its PHP quirks (WS-16),
re-learns sabre's DAV behaviour (WS-17), and re-derives the Mail draft lifecycle from the
PHP source (WS-23). Each piece here is mail-free or Mail-API-only and could live beside
`NextcloudUI` as a networking package. Not for the UI maintainer; recorded because the
library's README describes a family of apps, and these are the parts of that family that
are not views. The draft-lifecycle half is also server finding 38.

### A typed OCS envelope belongs next to the other shared models
**Workstream:** WS-16 · **Component:** proposed shared Nextcloud client kit · **Severity:** friction
**Where:** Packages/NCMailCore/Sources/NCMailCore/Models/Capabilities.swift (`OCSResponse`),
Models/TaskProcessing.swift, Models/Translation.swift, Models/ShareLink.swift, Models/Circle.swift
Five of the v2 routes are core or other-app OCS routes (translation, TaskProcessing, Smart
Picker references and unified search, files_sharing, Circles), and every Nextcloud client
needs the same `{"ocs":{"meta","data"}}` wrapper and the same PHP quirks — an empty map
serialised as `[]` (`taskprocessing/tasktypes` → `{"types":[]}`), a share `id` that is a
string while everything else is an integer. `nextcloud-swiftui` has none of this; each app
re-types it. Worth a small shared package of OCS models with lenient decoding, alongside
`NextcloudUI`, which this app would depend on instead of its own copies.

### A shared Nextcloud DAV client would be worth depending on
**Workstream:** WS-17 · **Component:** NextcloudKit-equivalent (missing component) · **Severity:** offer, not gap
**Where:** Packages/NCMailNet/Sources/NCMailNet/DAV/**
Every Nextcloud macOS/iOS client re-learns the same sabre facts, and `NCMailNet/DAV` is
~850 lines with no mail types: `DAVClient` over a transport protocol, a namespace-aware
`XMLParser` multistatus parser, sabre `d:error` mapping, request bodies for PROPFIND /
sync-collection / multiget / extended MKCOL / PROPPATCH / `oc:share`. The facts it encodes,
all recorded rather than read from docs: a truncated sync is a 207 with an in-band 507 for
the collection (ADR-0076); a vCard 4.0 PUT is re-served as sabre-normalised 3.0 yet
answers a strong ETag (the md5 of the bytes sent, against RFC 6352 §6.3.2.3's MUST NOT),
so an ETag does not prove the server holds your bytes; the calendar home is
`/calendars/<login>/` while the addressbook home is
`/addressbooks/users/<login>/`, so neither can be derived from the other; the addressbook
home lists synthetic `z-server-generated--system` and
`z-app-generated--contactsinteraction--recent` books a client usually wants to hide. The
content-line lexer in `NCMailCore/Contacts` (shared by vCard and iCalendar, lossless per
ADR-0075) is equally mail-free.

### The Mail draft API's `draftId` is a trap every client will fall into
**Workstream:** WS-23 · **Component:** nextcloud/mail API (upstream) · **Severity:** friction
**Where:** Packages/NCMailSync/Sources/NCMailSync/Outbox/OutboxRequest.swift
`draftId` on `POST /api/drafts` and `POST /api/outbox` reads as "the draft I am sending" and
is in fact the id of an IMAP message to expunge; passing a `/api/drafts` id there deletes an
unrelated message. Combined with the server job that silently deletes drafts idle for
300 s, a client cannot hold a draft id across a long compose without re-deriving all of this
from the PHP source (ADR-0083). Worth an upstream rename (`replacesMessageId`) or at least
API documentation; any shared Nextcloud Mail client kit should model the draft lifecycle
once rather than each app rediscovering it.

## v2: GRDB, SQLite, Foundation and swift-testing

### `databaseQuestionMarks(count:)` already parenthesises
**Workstream:** WS-18 · **Component:** GRDB · **Severity:** friction
**Where:** Packages/NCMailStore/Sources/NCMailStore/Queries/MailStore+Contacts.swift:24
Wrapping its result in `IN (…)` produces `IN ((?, ?))`, which SQLite parses as a row value
and rejects at runtime with "row value misused" — not at prepare time with a syntax error,
so only a test with two or more values catches it. `V2QueryTests.syncingAddressBooksPreservesTheMirrorsOwnColumns`
did; use `IN \(databaseQuestionMarks(count:))` bare.

### `ALTER TABLE ADD COLUMN` lands before the table constraints in `sqlite_master`
**Workstream:** WS-18 · **Component:** SQLite · **Severity:** polish
**Where:** docs/reference/schema.sql:57
Useful for anyone extending the schema-diff test pattern: SQLite rewrites the stored
`CREATE TABLE` text by inserting the added column after the last column definition and
*before* any table constraint, so the reference file can stay valid SQL with the v2
columns listed between `rawJSON` and the `UNIQUE` clause. Measured before committing to
ALTER over a table rebuild; `schemaMatchesReference` passes with the columns in that
position.

### `XMLParser` is fine for DAV once `shouldProcessNamespaces` is on
**Workstream:** WS-17 · **Component:** Foundation · **Severity:** polish
**Where:** Packages/NCMailNet/Sources/NCMailNet/DAV/DAVMultistatusParser.swift:44
sabre declares five prefixes (`d`, `s`, `card`/`cal`, `oc`, `nc`) and other servers pick
their own, so matching on prefixed element names is wrong by construction. With
`shouldProcessNamespaces = true` the delegate gets `(namespaceURI, localName)` and a
`DAVQualifiedName` pair is the whole model. sabre also encodes the CR of each CRLF in
`address-data`/`calendar-data` as `&#13;`, which XML line-end normalisation would
otherwise eat — so the embedded vCards come out of `XMLParser` with their CRLFs intact and
round-trip byte-identically (`addressbookMultigetCarriesWholeVCards`).

### `#require` cannot nest
**Workstream:** WS-24 · **Component:** swift-testing · **Severity:** papercut
`try #require(try await f(id: try #require(x)))` is a hard error (recursive macro expansion)
under warnings-as-errors, and one such line in one test file breaks every sibling's
`swift test`. Hoist the inner value first.

## v2: SwiftPM, the same link failure three times

**Workstreams:** WS-17, WS-16, WS-22 · **Severity:** friction

**Seen three times, and resolved in the build.** WS-17 hit a duplicate-symbol link failure
in `NCMailNet`'s tests, WS-16 showed it was the default build system and not concurrency,
and WS-22 found the separate `.build` lock that serialises sibling builds. The wave-1
integration pinned the native build system (commit `1e5ca99`, "pin the classic SwiftPM build
system"), so the first two are closed in this repository; the third is about running agents
in parallel and stands.

### Toolchain: NCMailNet tests did not link under the default SwiftPM build system
**Workstream:** WS-17 · **Component:** SwiftPM (Xcode 26 toolchain) · **Severity:** friction
**Where:** Packages/NCMailNet/Package.swift
With several agents building concurrently, `swift test` in `NCMailNet` failed at link time
with duplicate symbols, each listing the same `out/Products/Debug/NCMailNet.o` twice — the
package graph has `NCMailNet` reached directly and through `NCMailTestSupport`, which
depends on it. `--build-system native` with a private `--scratch-path` linked and ran every
time; a sibling reported a clean default-system scratch path also linked. Recorded so the
next person seeing `duplicate symbol … NCMailNet.o` tries a clean scratch path before
suspecting the sources.

### Toolchain: the duplicate-symbol link failure is the default build system, not concurrency
**Workstream:** WS-16 · **Component:** SwiftPM (Xcode 26 toolchain) · **Severity:** friction
**Where:** Packages/NCMailNet/Package.swift
Confirming WS-17's entry with one more data point: a brand-new `--scratch-path` under the
default build system still failed to link `NCMailNetTests` (same `NCMailNet.o` listed
twice), on a machine where no other build was using that path. `--build-system native`
linked first time. So it is not two agents sharing `.build`; it is the swift-build backend
with this package graph.

### Concurrent sibling builds of one package serialise on the `.build` lock
**Workstream:** WS-22 · **Component:** SwiftPM (toolchain) · **Severity:** friction
**Where:** Packages/NCMailSync
Four agents running `swift build --build-system native` in the same package directory queue
behind one lock; one WS-22 build waited the full 900 s timeout without compiling anything.
`--scratch-path /tmp/<own>` (still with `--build-system native`) builds in parallel and
links. Worth a line in the README's development section for anyone running agents in
parallel.

## v2: things that worked in the engines

Four engine workstreams with no UI recorded the same thing: one transport seam carried the
Mail API, DAV, OCS and 47 queue routes, so every client test looks alike.

### Things that worked (WS-17)
`MailTransport`/`FakeTransport` carried a second protocol family with no change: DAV
verbs, `Depth` headers and 207 bodies went through the same seam and the same
`RequestMatcher` as the Mail API, so the DAV tests look like every other client test.

### Things that worked (WS-16)
`FakeTransport` with `.fixture(name, status:)` made "every endpoint replayed through the
client with the status the live server answered" a one-line helper, which is what caught
the 202 problem (ADR-0077) before any caller existed.

### Things that worked (WS-23)
`FakeTransport.fail(_:times:then:)` throwing a real `MailError.transport` made "offline mid-
send" a two-line test; recorded `draft-*`/`outbox-*` fixtures covered every route the
engine calls.

### Things that worked (WS-22)
`RequestMatcher` composed with `&&` plus a path predicate made stubbing all 47 v2 routes
with recorded fixtures one table in `QueueV2TestSupport.stubV2`.

## v2: the Mail server, praise

Moved to "Things that are right" in [server-findings.md](server-findings.md) as well; kept
here because WS-22 wrote it here.

### Upstream answers a Sieve syntax error with a usable 422
**Workstream:** WS-22 · **Component:** nextcloud/mail API (upstream) · **Severity:** praise
`PUT /api/sieve/active/{id}` answers a script that does not parse with HTTP 422 and
`{"message": "<parser text with line and column>"}` (recorded live,
`error-sieve-script-422.json`) — exactly what a native form needs to show, with no scraping.

## The Mail server

WS-02 found that the server's JSON needs a lenient decoder in four specific places, and each
is a decoding failure for anyone who writes the obvious `Codable` conformance. An empty
`tags` map serialises as `[]` rather than `{}`, `mentionsMe` is `0`/`1` rather than a
boolean, `specialRole` is the integer `0` when there is no special use, and an unknown id
answers 403 with a body of `[]` rather than the documented error envelope.

Those were recorded here first because this file was the only place to append to. They
belong to the server's audience and are now findings 7 and 8 in
[server-findings.md](server-findings.md), counted against the recorded fixtures, with the
payloads documented in [api-payloads.md](../reference/api-payloads.md).

---

# Part 3: what each workstream contributed

Fifteen workstreams plus three cross-cutting passes appended to this file. This table is how
"every workstream is represented" is checked rather than claimed.

| Source | Contributed | Where it is now |
| --- | --- | --- |
| design pass | Missing icons, `NCListItem` leading slot, message-header block, six open questions, first "things that worked" list | Merged throughout Part 1. Both composition entries were later confirmed independently. |
| WS-00 | The warnings-as-errors blocker; `.ncTheme` in one line; `actool` emplaces `Assets.car` | Round-trip section; things that worked; question 4. |
| WS-01 | Nothing new, and it meant it. `NCButtonStyle`, `NCNoteCard`, `NCProgressStyle` covered a login screen with no workaround | Things that worked. Its open note that `LoginView` was unreachable is resolved: `RootSplitView.swift:38` shows it. |
| WS-02 | Test-support package cycle; `swift format` versus `#expect`; four server decoding quirks | Part 2, package cycle marked resolved. Server quirks moved to `server-findings.md`. |
| WS-03 | `WITHOUT ROWID` and `ValueObservation`; FTS5 has no upsert; the index the planner would not choose | Part 2, GRDB and SQLite. |
| WS-04 | Two store calls cannot share a transaction; `lastPrimedAt` had no DAO; the mirror draws nothing | Part 2, `NCMailStore`. One marked resolved. |
| WS-05 | Four store DAO gaps; `MailClient` reports no byte count; `FakeTransport.fail`; no view layer | Part 2. One gap half closed, three stand. The fake-transport entry is merged with WS-06's. |
| WS-06 | The queue had no store queries (blocker); `@testable` and a free function; GRDB re-export; `FakeTransport.fail` again | Part 2. The blocker is marked resolved; the fake-transport entry is merged with WS-05's. |
| WS-07 | `NCNavigationItem` does not combine its children; it composes inside `DisclosureGroup` perfectly; no new icons; question 3 still open | Accessibility pair; things that worked; open questions. |
| WS-08 | Leading slot confirmed with the shape it forced; the relative date measured; 50,000 rows measured; `NCCounterBubble(0)`; question 2 | API friction; performance; open questions. |
| WS-09 | `NCNoteCard` blocker; `NCListItem` missing initialiser; `NCChip` not activatable; the WebView belongs to the app; message-header block; `image-off-outline` | Leads Part 1. |
| WS-10 | `NCKeyboardShortcut` is right; `NCColorTokens` has no muted text; disabled icon buttons and `.help`; a `Menu` cannot hold a field | Things that worked; API friction; not-a-library-gap. |
| WS-11 | `NCHighlight` matches substrings, not terms; `.searchable` is the right answer; the coverage footer wanted no component | API friction; composition; not-a-library-gap. |
| WS-12 | `Form` and `NCNoteCard` composed with nothing to work around; settings tabs wanted three glyphs | Things that worked; missing icons. |
| WS-13 | Question 4 answered; question 3 answered provisionally; `MailSymbol` matches the design pass list; the eleven catalogue gaps in order; multi-account brand colour; `NCTheme` has no layout group | Missing icons; performance; open questions; not-a-library-gap. |
| WS-14 | **No entry of its own.** | Deliberate note rather than an omission: what WS-14 built closed WS-02's package-cycle entry, and the `FakeTransport.fail` gap its consumers recorded twice is the feedback on its API. A workstream whose deliverable is other workstreams' tooling is exactly the one whose feedback comes from its consumers. |
| wave-2 fixes | `lastPrimedAt` DAO landed; GRDB's overload pair; nothing drawn | Part 2. |
| store-DAO pass | `NCAvatar` and `NCUserBubble` take the right loader; the cache key includes the diameter; the queue DAO and four readers landed | Things that worked; question 6; Part 2 resolution markers. |
| security-audit fixes | The system SQLite's ASCII-only fold; FTS5 keeps deleted postings until `rebuild`; WebKit's menu identifiers have no header. `NCUserBubble`'s `trailing:` slot carried the sender's address with no workaround | Part 2, GRDB, SQLite and WebKit. The `NCUserBubble` result is a thing that worked and needed no entry. |

## v2 workstreams

Twenty-seven v2 workstreams. Three left no entry of their own in this file, and the table
says why for each, from their reports.

| Source | Contributed | Where it is now |
| --- | --- | --- |
| WS-16 | Typed OCS envelope for a shared kit; SwiftPM default build system; `FakeTransport.fixture` | Part 2, shared kit; SwiftPM merge; engine things that worked. Server: findings 17-21 |
| WS-17 | Shared DAV client offer; `XMLParser` namespaces; SwiftPM link failure; one seam for DAV | Part 2, shared kit; Foundation; SwiftPM merge; engine things that worked. Server: finding 39 |
| WS-18 | `databaseQuestionMarks` parenthesises; `ALTER TABLE ADD COLUMN` position. Nothing on `NextcloudUI`, no view | Part 2, GRDB and SQLite |
| WS-19 | **No entry of its own.** Its report lists recorder fixes and deliberate fixture gaps (no account create, replace or delete recordings; LLM, notifications and Sieve-off routes recorded as honest errors) | Considered and left out: a recorder has no `NextcloudUI` surface, and every server shape it recorded was written up by the workstream that consumed it (WS-16, WS-21, WS-24). Its scratch-lifecycle rules are ADR-0080 |
| WS-20 | `NCRichContenteditable` proposal; `NextcloudPlatform` unreachable; editor icons; TextKit 2 shortfalls; toolbar things that worked | Part 1b §3, §4, §8 (corrected), §12. Draft L-7 |
| WS-21 | `FakeTransport.stall` race; settings models cannot re-encode | Part 2, harness and own packages. Server: findings 23-25 |
| WS-22 | `.build` lock; Sieve's 422 is right; 47-route stub table | Part 2, SwiftPM merge; server praise; engine things that worked |
| WS-23 | The `draftId` trap; offline mid-send in two lines | Part 2, shared kit. Server: finding 38 |
| WS-24 | Multistatus parser flattened privileges (fixed); `RequestMatcher` path; `#require` nesting | Part 2. Server: findings 26-28 |
| WS-25 | Three actors with no `stop()`; `.local` in the hosted runner (resolved in the dev stack) | Part 2 |
| WS-26 | `NCPasteboard` unreachable; `NCProfileCard` selection; picker two-phase source | Part 1b §4, §10, §2 |
| WS-27 | `NCUserPicker` cannot be a recipient field; chip wrap, "+N", progress | Part 1b §2, §6. Server: findings 31-32 |
| WS-28 | Secondary count; drop target; picker search | Part 1b §9, §2 |
| WS-29 | Third line; styled subtitle; hover actions and density | Part 1b §5 |
| WS-30 | `NCNoteCard` controls and runtime text; assistant styling; expanded row | Part 1b §1, §7, §5. Server: findings 29-30 |
| WS-31 | **No entry of its own.** Its report notes two store columns, the web's snooze minutes quirk and the web's quick-action executor having no snooze step; its diff appends three `MailSymbol` cases and reuses `NCBreadcrumbs` | Workaround found and represented at curation: Part 2 "Two store columns triage reads from JSON"; `alarm-snooze` in §8; `NCBreadcrumbs` in §12. The two web-client notes are parity notes in ux-spec.md, not feedback |
| WS-32 | `NCChip` toggle | Part 1b §6 |
| WS-33 | File-type icons; disabled row; `NCBreadcrumbs` fitted | Part 1b §8, §5, §12 |
| WS-34 | Colour swatch; note card with actions; iMIP roles mapped | Part 1b §11, §1, §12. Server: findings 34-35 |
| WS-35 | Profile-card avatar; chip group; property row; cropper | Part 1b §10, §6, §11 |
| WS-36 | Caption accessory; leading-switch row; merge row; `Form` worked | Part 1b §9, §5, §11, §12 |
| WS-37 | Picker cannot search; action row; outline row; members drew with no changes | Part 1b §2, §9, §5, §12. Server: findings 36-37 |
| WS-38 | Icon button; dismissible error; tab icons; `Form` and `ComposerEditor` worked | Part 1b §7, §1, §4, §12 |
| WS-39 | **No entry of its own.** It reused WS-38's `SettingsIconButton` for quick actions and the editor for signatures | Represented through WS-38's icon-button entry (§7) and §3's consumer count. Server: finding 33 |
| WS-40 | Loading button; form message; `NCNoteCard(.info)` and `Form` worked | Part 1b §7, §1, §12. Server: finding 40 |
| WS-41 | Nothing from `NextcloudUI`; `App` has no hook for non-view code | Part 1b §13 |
| WS-42 | The widget extension cannot take the theme | Part 1b §4 |

---

# Append here

The standing obligation is unchanged: a workstream that touched the library and found a
workaround appends an entry below, in the format at the top of this file. The next
curation moves it into Part 1b or Part 2.

### No notice row for app-level news, so the update line copies the status footer
**Workstream:** in-app updates (ADR-0108) · **Component:** none (`NCNoteCard` considered) · **Severity:** polish
**Where:** NextcloudMail/Updates/UpdateViews.swift (`UpdateAvailableBanner`)
The sidebar line that says an update is waiting is a hand-built `HStack`: icon, caption,
tertiary small button, padded with `theme.metrics.spacing.tight`, the same as
`StatusFooter`. `NCNoteCard(.info)` is too heavy for permanent chrome at the bottom of a
sidebar, and its children are combined for accessibility, so the button inside it is
unreachable (see the existing `NCNoteCard` entry). What would have helped: a compact
`NCStatusRow(symbol:text:action:)` that both the status footer and this line could use.
The settings section needed nothing from the library: `Form` with `Picker`, `Toggle` and
`LabeledContent` worked as is.
