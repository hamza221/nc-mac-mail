<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Upstream issue drafts

*Ready for a human to post. Nothing here was filed by an agent.*

Twenty-five drafts. Thirteen were written by WS-15 for v1 on 2026-09-23; WS-43 extended
three of them with v2 evidence and added twelve on 2026-10-04.

| Repository | Drafts |
| --- | --- |
| [`hamza221/nextcloud-swiftui`](https://github.com/hamza221/nextcloud-swiftui) | L-1 to L-10 |
| [`nextcloud/mail`](https://github.com/nextcloud/mail) | M-1 to M-3, M-5 to M-13 |
| Nextcloud security inbox, not a public tracker | M-4 |
| [`nextcloud/server`](https://github.com/nextcloud/server) | S-1 to S-3 |
| [`nextcloud/circles`](https://github.com/nextcloud/circles) | C-1 |
| [`nextcloud/contacts`](https://github.com/nextcloud/contacts) | K-1 |

Each draft is a title and a body. The evidence behind each one, with the call sites, is in
[library-feedback.md](library-feedback.md) and [server-findings.md](server-findings.md).

**Before posting.** Read L-6 and M-4 first: L-6 asks for a CI job rather than a code change,
and M-4 is a privacy report that should not be a public issue. L-7 is an offer of code, not
a bug: post it as a discussion or an issue as the maintainer prefers.

## If only five get posted

Ranked by what each one changes for the most clients, across all repositories:

1. **L-1, `NCNoteCard` actions** (`nextcloud-swiftui`). Five workstreams and about a dozen
   call sites worked around it, it is an accessibility blocker, and the fix changes a
   signature, so it has to land before the API freezes.
2. **L-7, `NCRichContenteditable`** (`nextcloud-swiftui`). The largest deferred component on
   the roadmap, offered as working code with three consumers and 40 tests.
3. **L-8, `NCUserPicker` caller-owned results** (`nextcloud-swiftui`). Four workstreams, and
   no people-picking screen in v2 could use the picker. Changes the initialiser.
4. **M-9, the drafts and outbox contract** (`nextcloud/mail`). A literal reading of the API
   retries a send that succeeded or expunges an unrelated message.
5. **M-8, a configuration route for native clients** (`nextcloud/mail`). One capability and
   one batch preference route close six findings and cut a launch from 25 requests.

M-1 to M-6 (v1) still stand and are not re-ranked here: M-1 to M-3 are silent data loss for
any mirroring client and come before everything above for `nextcloud/mail`.

---

# For `hamza221/nextcloud-swiftui`

## L-1

**Title:** Accessibility: `NCNoteCard` and `NCNavigationItem` combine their children in
opposite directions, and both are wrong for one of their shapes

**Body:**

Found while building a Mail client against the library. Two components make the opposite
choice about `.accessibilityElement(children:)`, and each one is wrong for its second most
common use. They are one issue because one rule fixes both.

### `NCNoteCard` combines, so a control inside it disappears

`NCNoteCard`'s body ends with `.accessibilityElement(children: .combine)`
(`Sources/NextcloudUI/Components/NoteCard/NCNoteCard.swift:88`). That is right for a banner
that only explains.

A blocked remote content bar is a warning with two buttons, "Show images" and "Always show
from this sender". Put them in the content builder and VoiceOver reads the card as one label
and drops both buttons from the rotor. There is no way to opt out from the call site.

`NCChip` has the same constraint and solves it by re-surfacing removal as an accessibility
action (`Components/Chip/NCChip.swift:135-141`). `NCNoteCard` has no equivalent, so our bar
puts its buttons outside the card in an enclosing `VStack`, which is not the composition the
design asks for.

Three screens in one app want a banner with a button: blocked content, a failed body with
Retry, and a phishing warning.

**Suggested fix:** an `actions:` slot, `NCNoteCard(_:title:content:actions:)`, laid out by
the component and left outside the combined element. Failing that, use `children: .contain`
when the content builder holds anything focusable.

### `NCNavigationItem` does not combine, so every caller must

`NCNavigationItem`'s body is a plain `HStack`
(`Sources/NextcloudUI/Components/NavigationItem/NCNavigationItem.swift:72`). The title
`Text`, `NCCounterBubble` and the trailing actions `Menu` are three separate accessibility
elements, with none of the `.accessibilityElement(children: .combine)` that `NCListItem`
already applies (`Components/ListItem/NCListItem.swift:115`).

A sidebar mailbox row should read as "Inbox, 7 unread" in one stop. Left alone, VoiceOver
stops twice. Every caller drawing a list of navigation items has to know to combine them,
and has to know not to when the row carries an actions menu.

**Suggested fix:** combine when there is no `actions:` closure.
`NCNavigationItem<EmptyView>` has nothing a combine could break, and the common sidebar row
(icon, title, count, no menu) is exactly that shape.

### The rule the pair suggests

A component should combine its children when its generic parameters prove it has no
focusable content, and should not when a caller supplied any. Both components currently
choose based on their own most common use rather than on what the caller passed.

### Since this was first written: four more screens, and two more asks

Building the rest of the client (web-client parity plus Contacts and Calendar) hit
`NCNoteCard`'s `.combine` four more times, independently: seven message banners (phishing,
read receipt, follow-up, translation, remote content, S/MIME, PGP), invitation cards with
Accept / Decline / Tentative, itinerary cards with "Import into calendar", a dismissible
settings error, and an account-setup form message. Every one of them put its buttons beside
or under the card in a hand-built stack, so one app now has about a dozen slightly different
card-plus-buttons layouts. That is the strongest single signal from building the client.

Two more asks from the same call sites, both additive:

- **`onDismiss:`**, a close button the card owns, for an inline error that has to go away
  once read.
- **A verbatim `String` message.** `message:` is a `LocalizedStringResource`, so text from
  the server (phishing reasons, a date, a language name) needs the content-builder form and
  one `Text` per line.

## L-2

**Title:** `NCListItem`: the slots a mail row still has to build itself

**Body:**

`NCListItem` gives a row a title, a `String` subtitle, one leading view, details and one
trailing view (`Components/ListItem/NCListItem.swift:79`). Building a full Mail client and
a Contacts client against it, seven separate screens needed something the row does not
have. Each item below is a call site that rebuilds part of the library's layout from
outside.

**1. A footer line inside the text column** (the most important). A mail row is sender,
subject, then a preview and a line of tag and attachment chips. The row stacks a second block
under the item and indents it by `metrics.avatar.medium + metrics.spacing.standard` to line
up with the text column: a guess at the item's internal layout that breaks if the item
changes. A `footer:` slot removes the guess.

**2. A trailing accessory cluster beside `details:`.** Unread, starred and attachment glyphs.
We first built them as a fixed column ahead of the avatar, three `Color.clear` placeholders
wide, because a variable-width leading slot breaks vertical alignment. Seen in use, that was
a blank column on nearly every row, so the glyphs now go in `trailing:`, drawn only when they
apply, next to the right-aligned date. A cluster the component lays out there would replace
the spacing arithmetic. Files (shared, favourite, locked) and Talk (unread, mention) want the
same.

**3. A `Text` or `AttributedString` subtitle,** so a draft can read *Draft:* in italics
before the subject, as the web does.

**4. An `isEnabled`-aware look.** A "choose a folder" picker lists files dimmed and
unselectable; today the caller applies `.opacity(0.5)`.

**5. `hoverActions:` and an `.ncListDensity(.compact)` environment value.** Quick actions on
hover are an app-built overlay; compact mode switches the avatar size by hand.

**6. A disclosure form with an expanded content slot,** the web's `ThreadEnvelope`: a list of
collapsed rows around one expanded message.

**7. A leading control,** a switch before the name (address books, calendars), and **8. a
depth or outline form** with connectors (an organisation chart; nested mailboxes).

Several of these could be one generic slot API rather than eight parameters; that is the
maintainer's call. What matters is that the library owns the alignment, because three
Nextcloud apps reimplementing it will line their rows up three slightly different ways.

**Related, smaller.** There is no `NCListItem(_:subtitle:details:)`: the five initialisers
cover every combination except title, subtitle and details with no leading view. The source
comment says why, that an unlabelled trailing closure would match two overloads, and the
ambiguity argument does not apply to the labelled form the comment itself suggests. A thread
strip that wants sender, subject and date and deliberately no avatar currently has to draw
an avatar.

## L-3

**Title:** Icon catalogue: the eleven Material Design Icons a mail client needs

**Body:**

The catalogue ships 91 MDI assets behind 92 named constants. A full mail client was built
against it, and **eleven of the app's seventeen icons are not in the catalogue** and resolve
through `systemFallback` to an SF Symbol.

The fallback mechanism works exactly as documented, so this is friction and not a bug. It is
posted because the roadmap has an open question about which icons to curate next, and this
is a measured answer for one app rather than a guess.

In the order a mail client hits them:

| MDI name | Drawn for | SF Symbol used instead |
| --- | --- | --- |
| `inbox` | Inbox mailbox, empty state | `tray` |
| `send` | Sent mailbox | `paperplane` |
| `paperclip` | Attachment indicator and chips | `paperclip` |
| `email-open-outline` | Mark unread | `envelope.open` |
| `sync` | Syncing, downloading, failed | `arrow.triangle.2.circlepath` |
| `tag-outline` | Tags | `tag` |
| `reply` | Answered indicator | `arrowshape.turn.up.left` |
| `archive-arrow-down-outline` | Archive action and mailbox | `archivebox` |
| `file-document-outline` | Drafts mailbox | `doc.text` |
| `image-off-outline` | Blocked remote content | `photo.badge.exclamationmark` |
| `harddisk` | Storage settings | `internaldrive` |

`alarm` makes twelve if snooze ships. It is not drawn today, so it is not counted.

One of them is visibly wrong rather than approximate. With no `image-off-outline`, a
blocked-content bar falls back to the warning card's own alert glyph, which tells the reader
"warning" rather than "pictures not shown".

`alertOctagonOutline`, `trashCanOutline`, `folderOutline`, `star`, `cogOutline` and
`accountOutline` were already there and are used as they are.

**Since this was first written,** the client grew to 95 icons, and **57 of them** resolve to
a fallback: the eleven above plus forty-six more. In the order a mail-and-contacts client
draws them:

- **Editor (15):** `format-strikethrough-variant`, `format-subscript`, `format-superscript`,
  `image-plus`, `format-align-justify`, `format-pilcrow-arrow-right`,
  `format-pilcrow-arrow-left`, `format-list-bulleted`, `format-list-numbered`,
  `format-quote-close`, `format-clear`, `find-replace`, `code-tags`, `redo`, `format-text`.
  (`format-bold`, `format-italic`, `format-underline`, the left, centre and right aligns,
  `link-variant` and `undo` are already there.)
- **Message actions and banners (12):** `reply-all`, `share` (forward), `alarm-snooze`,
  `label-variant` (important), `printer`, `eye-outline`, `translate`,
  `email-remove-outline` (unsubscribe), `email-check-outline` (read receipt),
  `lock-off-outline`, `creation` (AI content), `email-outline`.
- **Mailboxes and navigation (6):** `inbox-multiple`, `label-variant-outline`,
  `inbox-arrow-up`, `folder-account-outline`, `chevron-left`, `view-split-vertical`.
- **Status (2):** `alert-outline`, `information-outline`.
- **Files (4):** `file-outline`, `file-image-outline`, `refresh`, `cloud-outline`, and
  ideally the whole MDI file-type set (pdf, document, spreadsheet, audio, video, archive).
- **Contacts, calendar and teams (7):** `domain`, `certificate-outline`,
  `cloud-download-outline`, `airplane`, `train`, `sitemap-outline`, `logout`.

`alarm` in the paragraph above is now `alarm-snooze`, which is what snooze draws.

## L-4

**Title:** `NCRelativeDateFormatter`: a list date needs to go absolute past a cutoff

**Body:**

`NCListItemDetails`'s default formatter is
`NCRelativeDateFormatter(width: .short, ignoresSeconds: true)`, which is
`Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated)`. Measured output,
`en_US`:

| Age | Rendered |
| --- | --- |
| 3 minutes | `3 min. ago` |
| 2 hours | `2 hr. ago` |
| 1 day | `yesterday` |
| 5 days | `5 days ago` |
| 9 days | `last wk.` |
| 40 days | `last mo.` |
| 280 days | `9 mo. ago` |

The first four are right. Past about a week it stops being useful for a list:

- Two messages three weeks apart both read `last mo.`, so the column that orders the list
  stops ordering it.
- `9 mo. ago` is longer than `12 Mar` in a column that is 280 points wide in total.

Every mail client switches to an absolute date past roughly a week, and a conversation list
wants the same rule.

**The escape hatch does not escape.** `NCListItemDetails(date:unreadCount:formatter:)` takes
an `NCRelativeDateFormatter`, and that type has `width`, `ignoresSeconds` and `locale`. None
of them can express "relative under a week, absolute over it", so a caller who wants mail
rules cannot use `NCListItemDetails` at all and has to draw the date itself, losing the
component.

**Suggested fix:** `cutoff: Duration?` on `NCRelativeDateFormatter`, past which it formats
absolutely, `.dateTime.day().month(.abbreviated)` within the year and `.year()` beyond it.
Failing that, type `NCListItemDetails`'s `formatter:` as `some FormatStyle<Date, String>` so
a caller can supply anything.

## L-5

**Title:** Four small API asks from building a mail client

**Body:**

Each of these cost a workaround at one call site. None blocked anything. Grouped because
they are all small.

**1. `NCChip` cannot be activated.** It takes `onRemove:` and nothing else
(`Components/Chip/NCChip.swift:36-42`). An attachment chip is a control: clicking it saves
or previews the file. Today that is the chip inside a `Button` with `.buttonStyle(.plain)`,
with the caller supplying the accessibility label and the tooltip. `NCUserBubble` already
takes an `action:` (`Components/UserBubble/NCUserBubble.swift:50`); the same parameter on
`NCChip` would take the pointer style and hit target back into the library.

**2. `NCHighlight` matches a substring, and a full-text index matches terms.**
`NCHighlight.ranges(in:matching:)` trims the query and looks for that whole string
(`Components/Highlight/NCHighlight.swift:24`), which is right for filtering names and wrong
for search results. The query `hedgehog census` against an FTS5 index is
`"hedgehog"* AND "census"*`: two terms, either order, anywhere in the message. A matching
row can have one term in the subject and the other forty words into the preview, and
`NCHighlight` marks neither, so the reader sees a result with nothing highlighted and no
clue why it matched. An overload taking the terms,
`ranges(in:matchingAny: ["hedgehog", "census"])` plus `NCHighlightText(_:matchingAny:)`,
would fix it, and prefix semantics come free because each term is already matched as a
substring.

**3. `NCColorTokens` has no colour for text that should recede.** There is `primary`,
`primaryHover`, `primarySurface`, `onPrimary`, `onPrimarySurface`, four status families,
`favorite`, `highlight`, `userStatus` and `assistant`, and nothing equivalent to the web's
`--color-text-maxcontrast`. Empty-state lines, captions and timestamps fall back to
SwiftUI's `.secondary`, so one string in a Nextcloud-themed popover is coloured by the
system rather than by the theme.

**4. `NCKeyboardShortcut` could document a collision check.** A table of thirteen shortcuts
wants to assert that no two of them are the same key. The type is already `Hashable`, so
putting them in a `Set` and comparing counts works. One line in the DocC page would save the
next caller from comparing rendered strings, which is what we did.

## L-6

**Title:** CI cannot catch Xcode-only build failures by building the package itself

**Body:**

This is a process issue, not a code one, and it is the most useful thing we found.

`.treatAllWarnings(as: .error)` in the manifest made the package unbuildable from any Xcode
project that depended on it. Xcode hands every package target `-suppress-warnings`, the
setting produced `-warnings-as-errors`, and swiftc refuses the pair:

```
error: conflicting options '-warnings-as-errors' and '-suppress-warnings'
** BUILD FAILED **
```

No consumer could fix it. `xcodebuild SUPPRESS_WARNINGS=NO` on the command line works,
because a command-line setting reaches the synthesised package projects.
`SUPPRESS_WARNINGS = NO` in the consumer's own `.xcodeproj` does not. So Cmd-B in the Xcode
GUI could not be made to work at all while the setting was in the manifest.

That is fixed ([#2](https://github.com/hamza221/nextcloud-swiftui/pull/2), `1e753cb`), and
verified from a consumer: bare `xcodebuild -scheme NextcloudMail build` now succeeds with no
override.

**What has not changed is why CI never saw it.** `swift build` never passes
`-suppress-warnings`, and neither does `xcodebuild` when the package is the root. The flag
appears only when the package is a dependency of another project's target, and no job in
this repository is ever in that position.

**Suggested fix:** one CI job that creates a throwaway Xcode app target, adds this package
as a dependency, and runs bare `xcodebuild build` with no `SUPPRESS_WARNINGS` override. It
would have caught this on day one, and it is the only shape of job that can catch the next
one.

**Related, small:** `REUSE.toml:30` still has a `Showcase/**/*.pbxproj` glob with no project
behind it. When that project appears, it will be the first in-repo consumer and it will hit
exactly this class of problem.

## L-7

**Title:** Offer: a native `NCRichContenteditable`, built to be upstreamed, with three
consumers already

**Body:**

The roadmap defers `NCRichContenteditable` to v1.1 ("needs `NSTextView` bridging, 3–4
person-weeks alone"). A Mail client built against this library could not wait for it, so it
built one designed to move here: no mail types anywhere, theming through `.ncTheme`, every
control labelled. This issue offers it, says what it does and does not do, and lists what
would change on the way in. Code: `NextcloudMail/Editor/` in
[nc-mac-mail](https://github.com/hamza221/nc-mac-mail), twelve files, about 2,500 lines,
plus a 268-line HTML tokenizer it depends on. Same author and the same licence
(AGPL-3.0-or-later) as this library.

**What it is.**

- **A TextKit 2 `NSTextView`** (`ComposerTextView`), wrapped as `RichTextEditor`
  (`NSViewRepresentable`) and composed with a toolbar as
  `ComposerEditor(document:providers:onFileDrop:onMention:)`.
- **An `@Observable` document** (`EditorDocument`) with two modes, `.plain` and `.rich`, and
  every formatting operation as a method with a registered undo inverse, so the toolbar,
  menus and keyboard shortcuts drive one model. Switching rich to plain asks first when the
  text has formatting.
- **Its own HTML, in both directions.** `HTMLSerializer` writes one canonical spelling of a
  fixed tag set (p, br, strong, em, u, s, sub, sup, h1–h3, ul/ol/li, blockquote, a, img,
  span with colour, background, family and size, `dir`, `text-align`), with a fixed nesting
  order and property order, so serialise → import → serialise is a fixed point. 33
  parameterised fixed-point cases test it construct by construct. `HTMLImporter` reads any
  HTML into that model and never calls `NSAttributedString(html:)`, so it never runs WebKit
  and never fetches. Only `data:` images and `http`, `https` and `mailto` links can enter the
  model.
- **A full toolbar:** heading, family and size; bold, italic, underline, strikethrough;
  text and background colour (SwiftUI `ColorPicker`); sub- and superscript; image embed;
  alignment; left-to-right and right-to-left; lists; quote; link; remove formatting;
  `NSTextFinder` find and replace; an editable source view; undo and redo.
- **Trigger sessions:** `:` (emoji), `@` (mention), `!` (text blocks) and `/` (smart picker),
  each behind a provider protocol (`MentionProvider`, `TextBlockProvider`,
  `SmartPickerProvider`) so the editor never learns what a suggestion is.
- **A restricted pasteboard.** `readablePasteboardTypes` excludes web archives, and
  `readSelection(from:type:)` never calls `super` for HTML, so pasted HTML goes through the
  importer and a remote image on the pasteboard does not survive.

**Evidence that it is general.** It carries a mail composer, a per-identity signature
editor, and a text-block editor in Settings, which took it as it was. 40 unit
tests across four suites. Design records:
[ADR-0065](https://github.com/hamza221/nc-mac-mail/blob/main/docs/decisions/0065-native-rich-text-editor.md)
(why native),
[ADR-0073](https://github.com/hamza221/nc-mac-mail/blob/main/docs/decisions/0073-editor-canonical-html.md)
(the canonical HTML),
[ADR-0074](https://github.com/hamza221/nc-mac-mail/blob/main/docs/decisions/0074-editor-triggers.md)
(triggers).

**What TextKit 2 does not give, which an upstream design should know before it starts.**

- **No inline image resize handles.** `NSTextAttachment` has none; building them means custom
  hit-testing over `NSTextLayoutManager` fragments. The editor ships without interactive
  resize; `width` survives the round trip.
- **`NSTextList` numbering is per list instance.** Splitting a list mid-edit restarts the
  numbering at the split. Cosmetic here, because block identity lives in a custom attribute
  rather than in the text list, which is also why the serialised HTML stays right.
- **`NSTextView`'s HTML reading is WebKit's.** It goes through `NSAttributedString(html:)`,
  which can fetch. There is no reader hook to replace; the only safe seam is overriding
  `readSelection(from:type:)` and never calling `super` for `.html`. Anyone building a
  Nextcloud editor needs this one.
- **No typed API for the find bar's replace mode.** The caller fabricates an `NSMenuItem`
  whose tag is `NSTextFinder.Action.showReplaceInterface.rawValue`.
- `Unicode.Scalar.Properties` has no `isExtendedPictographic`, so the emoji trigger
  approximates.

**What would change on the way in.**

1. The tokenizer (`HTMLScanner` and `HTMLEntities`, 268 lines, also mail-free) moves with
   the editor.
2. Types become `public` and get `NC` names: `NCRichContenteditable` for the composed view,
   `NCRichTextDocument` for the model, the three provider protocols as they are.
3. `NCEmojiPalette` has to be reachable from the module the editor lands in; today it lives
   in `NextcloudPlatform`, which is not a product (see L-9).
4. Fifteen toolbar glyphs are missing from the catalogue (see L-3).
5. macOS only today. The serialiser and importer are attributed-string code a `UITextView`
   host could share; the view and pasteboard layers are AppKit.

**Not included, deliberately:** anything that knows about mail (signatures, quoting, the
recipient field).

**Question for the maintainer:** take it as one component, or split the HTML model
(`NCRichTextDocument` with its serialiser and importer, platform-neutral) from the AppKit
view? The second makes an iOS host cheaper later and keeps the canonical HTML a contract
with one owner.

## L-8

**Title:** `NCUserPicker`: let the caller own the results (a search-driven picker and a
token field)

**Body:**

`NCUserPicker` takes a `candidates:` list and filters it by substring itself
(`Components/UserPicker/NCUserPicker.swift:63,74`). That fits a short, local, unranked list.
Building a Mail and Contacts client, four separate screens needed to pick people, and **none
of them could use the picker**:

- **Recipient autocomplete** yields a local list at once and a longer one when a server
  supplement lands, ranked by rules the picker does not know (recency, frequency, identities
  last). The picker re-filters, so it cannot show a pre-ranked, growing list.
- **A recipient field** takes free-typed addresses (valid ones become chips, invalid text
  stays to be fixed), pasted lists with names, suggestions that arrive while typing, and
  refuses duplicates case-insensitively. None of that is "pick an id from a pool".
- **Mailbox delegation** picks one Nextcloud user from a server search. It fell back to a
  user-id `TextField`.
- **Adding team members** searches users and groups on the sharees route, about a third of a
  second per term. It became a `TextField` over a `List` of `NCListItem`s.

**Suggested fix, two shapes:**

1. **A search-driven picker:** results supplied by the caller (`results: [Candidate]`, or
   `search: (String) async -> [Candidate]`), no internal filtering, and a pending state
   while results are fetched.
2. **A token field:** `NCTokenField(tokens: Binding<[Token]>, text: Binding<String>,
   suggestions: [Suggestion], commit: (String) -> [Token])`, where the caller owns parsing
   and suggestions. It needs chips that wrap (L-10).

Both change or add initialisers, which is why this is worth settling before the API freezes.

## L-9

**Title:** Packaging: `NextcloudPlatform` is neither a product nor re-exported, and an app
extension cannot take the tokens alone

**Body:**

`Package.swift` declares three products (`NextcloudDesign`, `NextcloudUI`,
`NextcloudIcons`), and `Sources/NextcloudUI/Exports.swift` re-exports `NextcloudDesign` and
`NextcloudIcons`. `NextcloudPlatform`, which holds `NCEmojiPalette` and `NCPasteboard`, is
neither.

Two parts of one app made opposite choices about it. The editor writes
`import NextcloudPlatform`, which compiles only because Xcode puts every package target's
module in the build directory, which is an implementation detail and not an API. The contact
card refused to rely on that and writes `NSPasteboard` directly instead of
`NCPasteboard.copy`. An API that admits both is not frozen.

Two neighbouring asks belong to the same decision:

- **A dependency-free tokens product.** A WidgetKit extension will not link the whole UI
  package and its asset catalogues for a few metrics and a brand colour, so the widgets fall
  back to system styles. A `NextcloudUITokens` product (metrics and the brand colour as plain
  values) would let an extension follow the app.
- **An `Image` from an `NCSymbol`.** SwiftUI's `tabItem` takes `Label(_:image:)`, and the
  catalogue hands out a view, so a settings window with eleven tabs has no tab icons.

**Suggested fix:** add `NextcloudPlatform` to `Exports.swift` or make it a product; split
the token values into a product with no resources; add an `Image` accessor (or a `Label`
helper) on `NCSymbol`.

## L-10

**Title:** `NCChip`: a wrapping group, a selectable form, a "+N" limit and progress

**Body:**

`NCChip` is a display token: a role, a tint, an optional leading view and `onRemove:`
(`Components/Chip/NCChip.swift:36`). Five places in one client needed it to be a control:

- **A wrapping group, built twice.** A recipient field and an attachment strip
  (`FlowLayout`), and a contact's groups (`ContactFlowLayout`), each wrote a SwiftUI `Layout`
  that wraps chips. `NCUserPicker`'s own chips scroll on one line. An `NCChipGroup` that
  wraps with the theme's spacing would serve Mail, Deck labels and Talk participants.
- **A limit with "+N more".** Long recipient lists collapse to "+N" in the composer and past
  three in the message header; both hand-roll a borderless button after the chips. The group
  could own the limit, the wording and its accessibility.
- **A selectable form.** Search filters (has attachment, unread, to me) are the web's
  `NcChip` with a selected state. Today: a chip in a plain `Button`, the role swapped by
  hand, the `.isSelected` trait added by the caller. `NCChip(_:isOn:)` would own all three.
- **Progress and failure.** An uploading attachment wants a progress bar and a failed state:
  `progress: Double?` or a trailing slot.
- **An action** (from L-5): the `action:` parameter `NCUserBubble` already has.

---

# For `nextcloud/mail`

All findings are against **5.12.0-rc.1** (`appinfo/info.xml`), `main`, exercised by a native
macOS client that downloads every subscribed mailbox and keeps a complete local copy.

## M-1

**Title:** `newMessages` in the sync response contains thread heads only, so a mirroring
client silently misses messages

**Body:**

`lib/Db/MessageMapper.php::findNewIds` self-joins on `thread_root_id` and keeps rows where
`m2.id IS NULL`, so only thread heads come back. That is threaded-view filtering applied to
a sync response.

Two new messages arrive in the same thread and a client hears about one. For the web client,
which renders thread heads, this is invisible. For any client that keeps a full local copy
it is silent data loss: nothing errors, no count disagrees, and the missing message is only
found by paging the whole message list again as a safety net, which is what we now do after
every sync.

**Suggested fix:** return every new message from sync regardless of threading, and let the
client group them. Threading is a display concern; sync is not display.

Version: 5.12.0-rc.1.

## M-2

**Title:** `GET /api/messages`: `cursor` is strictly exclusive, so two messages sharing a
`dateInt` at a page boundary are unreachable

**Body:**

`cursor` is a `dateInt` and `lib/Db/MessageMapper.php::findIdsByQuery` compares with `<`.

Reproduction against 5.12.0-rc.1:

```
GET /api/messages?mailboxId=5&view=singleton&limit=3     # last item dateInt 1789590490
GET /api/messages?mailboxId=5&view=singleton&cursor=1789590490
   -> only messages strictly older than 1789590490
```

`dateInt` is second resolution, and two messages can share one. The test account's inbox has
ids 44 and 45 both at 1778515439. When `limit` falls between two such messages, a client
sends the first one's `dateInt` as the cursor and **the second is unreachable by
pagination**. No error, no gap in any count the client can see, and no second chance,
because every later page is strictly older.

A client can work around it by sending `oldest dateInt + 1` and dropping one duplicated row
per page, which is what we do, but a client that reads the parameter's name and does the
obvious thing loses mail. The web client never hits it because it never enumerates a whole
mailbox.

**Suggested fix:** make the cursor a `(dateInt, id)` pair, or document the `+ 1` in the
OpenAPI spec.

Version: 5.12.0-rc.1.

## M-3

**Title:** `GET /api/messages` should accept `sortOrder`: today a stored preference silently
inverts pagination

**Body:**

`lib/Controller/MessagesController.php::index` takes no sort-order parameter. It reads the
user's stored `sort-order` preference, and that single value changes two things at once:
which end of the mailbox page one comes from, and which way `cursor` compares.

Measured on a live 5.12.0-rc.1 instance, setting the preference and putting it back:

| | `newest` or unset | `oldest` |
| --- | --- | --- |
| `limit=5` | ids 167, 166, 165, 164, 154 (newest first) | ids 23, 24, 25, 26, 27 (oldest first) |
| `cursor=<dateInt>` | returns messages **older** than it | returns messages **newer** than it |
| `&sortOrder=newest` in the query string | ignored | ignored |

Consequences for any client that enumerates a mailbox:

- Pagination arithmetic has to flip with a value the client did not send and cannot override
  per request.
- A "page from the newest until you recognise everything" scan cannot be expressed at all
  under `oldest`, because the newest messages are at the far end of the walk.
- A second client changing the preference changes the first client's pagination mid-run.

The failure is silent in the worst way. Nothing errors. The enumeration advances by one row
per page instead of by a hundred, so a mailbox that took 500 requests takes 50,000 and looks
like a slow server.

**Suggested fix:** accept `sortOrder` as a query parameter, defaulting to the preference.
`POST /sync` already accepts it in its body. It is one line in the controller, and it lets a
client ask for what it needs without writing to a user-visible setting.

Version: 5.12.0-rc.1.

## M-4

**Do not post this one publicly.** It describes a way to get a request out of a message
whose images the user has blocked. Send it to <security@nextcloud.com> or through
<https://hackerone.com/nextcloud>, and open a public issue only if they ask for one.

**Title:** `TransformImageSrc` rewrites `<img>` but not CSS, so `@import` in a `<style>`
block survives image blocking

**Body:**

`lib/Service/HtmlPurify/TransformImageSrc.php` replaces every remote `<img src>` with a
blocked placeholder and keeps the original in `data-original-src`. HTMLPurifier keeps
`<style>` blocks, and nothing in the chain touches URLs inside them.

A real marketing email, fetched through `GET /api/messages/{id}/body?plain=true` on
5.12.0-rc.1, comes back with nine images blocked, a 1x1 tracking pixel neutralised, and a
`<style>` block that opens with:

```css
@import url(https://static-forms.klaviyo.com/fonts/api/v1/U45QAK/custom_fonts.css);
```

A client that renders that fragment fetches it. It is a host the user never agreed to
contact, it is not covered by the image blocking, and it tells the sender's CDN when the
message was opened and from roughly where, in a message whose images are all blocked.

The web client renders the fragment in an iframe with a CSP, which may or may not stop it
depending on the policy. A native client has no CSP, and the reason it has none is that the
server does this sanitising on its behalf.

Same document, same risk, different element: `url(...)` in a `background-image` is
untouched too.

**What our client does:** deletes every `@import` and rewrites every `url(...)` through the
same allowlist as `<img>`. Messages lose web fonts and CSS backgrounds the server would have
proxied happily.

**Suggested fix:** extend the transform to CSS `url()` and `@import`, either dropping them
or routing them through `/proxy` the way images go. The proxy already exists and already
signs its URLs.

Version: 5.12.0-rc.1.

## M-5

**Title:** `POST /sync` returns every id the client claims to know, and the `TODO` for change
detection is still in the file

**Body:**

`lib/Service/Sync/SyncService.php::getDatabaseSyncChanges` carries its own
`// TODO: $changed = $this->messageMapper->findChanged(...)`. Until that is implemented,
`changedMessages` is every id in the request that still exists, serialised in full.

For a client with a complete local copy this is the difference between a sync and a full
download. The only options are to send a small window of ids and accept blind spots outside
it, which is what we do, or to send everything and receive the mailbox back.

**Suggested fix:** implement the `TODO`, or add a `since` token so a client can ask what
changed since X instead of describing everything it holds.

Version: 5.12.0-rc.1.

## M-6

**Title:** Feature request: a bulk body endpoint, and the measurement that argues for it

**Body:**

`GET /api/messages/{id}/body` (`lib/Controller/MessagesController.php::getBody`) opens an
IMAP connection, fetches one message, parses and sanitises it. Mirroring a 50,000-message
account means 50,000 of those, and it is the single largest cost of being a native client.

**The measurement.** Mirroring a 155-message account three times with identical code and two
body fetches in flight took **183 s, 213 s and 1,498 s**. The request count is identical
every time. What varies, by a factor of eight, is how long `/body` takes to open its IMAP
connection, fetch, parse and sanitise. A client cannot improve this by being politer,
because it is already inside its concurrency budget. At 1.4 s per message, a 50,000-message
account is 19 hours of server time spent one message at a time.

**Suggested fix:** `POST /api/messages/bodies` taking up to about 50 ids and returning them
in one response, reusing one IMAP connection. It cuts round trips by a factor of fifty and
lets the server choose the batch size, which is better than every client guessing.

Version: 5.12.0-rc.1.

## M-7

**Title:** Seven payload shapes that cost a strictly typed client an afternoon each

**Body:**

All found writing a typed client against recorded 5.12.0-rc.1 responses. Each is small.
Together they are most of what a new client's first week is spent on. Counts are from
recorded payloads, not from reading the source.

**1. PHP's types reach the wire in three places.**
`tags` is a dictionary keyed by IMAP label, except when it is empty: PHP serialises an empty
associative array as `[]`, so **7 of 95 envelopes** in one recorded page send `"tags": []`
and the other 88 send an object (`lib/Db/Message.php::jsonSerialize`). `mentionsMe` is the
integer `0` or `1` rather than a boolean, because it is written by a `COUNT(*)` and never
cast. `specialRole` is `$specialUse[0] ?? 0`, so it is a string or the integer `0`, and **2
of 7 mailboxes** send the integer (`lib/Db/Mailbox.php::jsonSerialize`). Casting at the point
of serialisation fixes all three.

**2. A stale id answers 403 with a body of `[]`.** Not the `JsonResponse::fail` envelope the
rest of the API uses:

```
GET /api/mailboxes/99999999/stats   -> 403  []
GET /api/messages/99999999          -> 403  []
GET /api/messages/99999999/body     -> 403  []
```

`DelegationService` resolves the effective user before the controller runs, so "gone" and
"never yours" are the same answer, which is defensible. What costs a client a day is that
403 here does **not** mean the account lost its delegation. It is the ordinary answer to a
stale id, which a mirroring client produces every time someone deletes a message in the web
client. A client that treats 403 as an auth failure signs the user out for no reason.
`POST /api/mailboxes/{id}/sync` on a missing mailbox answers 405 with an HTML body, a third
shape for the same event. Documenting this would be enough.

**3. `flags` is an object on the envelope and an array on the body.**
`lib/Db/Message.php::jsonSerialize` versus `lib/Model/IMAPMessage.php::jsonSerialize`. One
extra model in every typed client. The object form is the more useful one.

**4. `mailbox.id` is `base64_encode($this->getName())`.** A field called `id` that is not the
identifier, next to `databaseId` which is, next to an always-empty `mailboxes` array that
looks like it should hold the hierarchy. Renaming would break clients; a line in the OpenAPI
spec is free.

**5. `displayName` is the full IMAP path**
(`lib/Db/Mailbox.php::jsonSerialize`, `'displayName' => $this->getName()`). Every client
splits it on the delimiter, so every client reimplements the same function. A `leafName`
would do.

**6. `selectable` is computed and then not serialised.** `lib/IMAP/MailboxSync.php:220` sets
it; `jsonSerialize` omits it, so clients re-derive it from `attributes` containing
`\noselect`. Subscription is the same story, and the Vue client lowercases before comparing
(`src/components/NavigationMailbox.vue:289`), so every client must know to do the same.
Serialising both as booleans costs nothing; the information is already computed.

**7. Two names for the destination mailbox.**
`lib/Controller/MessagesController.php:379` takes `destFolderId`;
`lib/Controller/ThreadController.php:55` takes `destMailboxId`. Accepting both on both and
deprecating one would end it.

**One thing that looks like a bug and is not, and should be documented as deliberate.** In a
sanitised body, nine of ten images carry `data-original-src` and the 1x1 tracking pixel
carries none, so "show images" can never restore it. That is exactly right, and a client
author who "fixes" the apparent inconsistency would quietly undo it. One sentence in the
transform's doc block would prevent that.

Version: 5.12.0-rc.1.

## M-8

**Title:** Native clients need the configuration the web page gets as initial state: a
`mail` capability and one preferences route

**Body:**

`lib/Controller/PageController.php::index` provides the web client, as initial state,
values a native client has no other way to read: `allow-new-accounts`,
`disable-scheduled-send`, `disable-snooze`, `importance_classification_default`,
`google-oauth-url`, `microsoft-oauth-url`, and the `preferences` blob with
`attachment-size-limit`. Capabilities carry no `mail` section, `GET /api/preferences/{key}`
reads user preferences only, and the provisioning API exposes three of the app-config keys,
to admins only. A native client has to assume every feature is on and learn otherwise from
an error. Six consequences, found building a native macOS client:

1. **The flags themselves are unreadable** (above).
2. **A settings refresh is 25 requests.** Fifteen are `GET /api/preferences/{key}`, one key
   each. At about 210 ms of PHP bootstrap per Mail route on the test server, that is 7.3 s
   serially and 2.6–3.1 s four at a time.
3. **Translation off is invisible.** With no provider, `GET /ocs/v2.php/translation/languages`
   answers 200 with an empty list and `POST …/translate` answers OCS 412. Mail's own
   `llm_translation_enabled` is the only real signal, and a user cannot read it.
4. **"New accounts disabled" answers a generic error.**
   `AccountsController::create`'s `ALLOW_NEW_MAIL_ACCOUNTS` check returns
   `MailJsonResponse::error('Could not create account')`, the same text as an unexpected
   `ServiceException` a few lines later.
5. **Omitting `classificationEnabled` on create ignores the admin default.** The controller
   passes `null`, `MailAccount` keeps its property default `true`, and only the CLI commands
   call `isClassificationEnabledByDefault()`. The web form always sends the value, so it
   never notices.
6. **`attachment-size-limit`, `disable-scheduled-send` and `disable-snooze` are enforced only
   in Vue.** `AttachmentsController`, `OutboxController` and the snooze routes never check
   them, so a client that cannot read them (1) cannot honour them, and the server accepts
   the request anyway.

**Suggested fix:** a `mail` capability (or `GET /ocs/v2.php/apps/mail/config`) with the
values `PageController` already computes, including whether translation is available, and
`GET /api/preferences` returning every user preference at once. Then, smaller: a 403 with
"Creating mail accounts is disabled by your administrator"; apply
`ClassificationSettingsService::isClassificationEnabledByDefault()` when the parameter is
null; check the three flags server-side.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

## M-9

**Title:** Drafts and outbox: 202 means "done", `draftId` deletes a message, and an SMTP
refusal looks like a retry

**Body:**

Three ways a client that reads the drafts and outbox API literally does the wrong thing with
a user's outgoing mail. Each one was found building a native client, and each risks a
duplicate or a lost message.

**1. 202 means two opposite things.** `MailboxesController`'s sync answers
`JsonResponse::fail([], 202)`: not done, ask again. `DraftsController::update`, `destroy`
and `move`, and `OutboxController::update`, `send` and `destroy`, answer
`JsonResponse::success(…, 202)`: done. A client that learns 202 from sync treats every
successful draft save and every successful send as a failure, and a queue that retries a
"failed" send **sends it twice**. Suggested: 200 for the drafts and outbox successes.

**2. `draftId` is the IMAP message to expunge.** On `POST /api/drafts` and `POST
/api/outbox` it reads as "the draft I am sending". It is the database id of an IMAP message
that the server flags `\Deleted` and expunges (`DraftsController.php:94-95`,
`handleDraft`). Passing a `/api/drafts` id there deletes an unrelated message. Separately,
`DraftsService::flush` moves every draft untouched for 300 s with no `send_at` into the
IMAP Drafts folder and deletes the row (`LocalMessageMapper.php:188`), so a client holding a
draft id across a long compose finds it gone. Neither is in the API description. Suggested:
rename to `replacesMessageId` (or document it), document the 300 s job, and consider an
idempotency key on send so a client can retry safely.

**3. An SMTP refusal is invisible.** When the relay refuses (here an SMTP 452 4.3.1,
"Insufficient system storage", logged as a `Horde_Mime_Exception` from
`MailTransmission::send`), `POST /api/outbox/{id}` answers 500 "Could not send message", and
the message stays in the outbox with `status` 10 (`STATUS_SMPT_SEND_FAIL`,
`LocalMessage.php:75`) and **`failed: false`**. Cron retries it against the same relay. A
client cannot tell "will retry" from "the relay said no" without knowing the status table.
Suggested: set `failed`, or expose the SMTP reply, when the transport refuses.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

## M-10

**Title:** `PUT /api/accounts/{id}` answers a half-empty account, so a client that trusts
the answer wipes the account's settings

**Body:**

`PUT /api/accounts/{id}` answers with `order`, `editorMode` and every special-mailbox id
(`draftsMailboxId`, `sentMailboxId`, `trashMailboxId`, `junkMailboxId`, …) as **null**,
while the stored account keeps them: the next `GET /api/accounts/{id}` has them all.

`AccountsController::update` (`lib/Controller/AccountsController.php:169`) returns
`SetupService::createNewAccount(…, $id)`, which builds a fresh `MailAccount` from the
request's connection fields only, saves it, and serialises that object rather than the row
the update produced. `create` (`:378`) returns the same serialiser's answer.

A client that upserts the answer, which is the obvious thing to do with the body of a PUT,
loses the account's writing mode and default folders. Ours now re-reads the account with a
GET after both the PUT and the POST, and trusts only the POST's `id`.

**Suggested fix:** return `accountService->find($userId, $id)` after the save, as `show`
does.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

## M-11

**Title:** Two reads a mirroring client cannot rely on: the message list answers 409 during
any sync, and `dkimValid` is missing from bodies

**Body:**

**1. `GET /api/mailboxes/{id}/messages` answers 409 while any sync of the mailbox runs.**
`MailSearch::findMessages` throws `MailboxLockedException` ("{id} is already being synced",
`lib/Service/Search/MailSearch.php:81`) whenever the mailbox holds any of its three sync
locks, including one taken by another client or the background job, for up to
`Mailbox::LOCK_TIMEOUT` (300 s, `lib/Db/Mailbox.php:93`). A read that does not touch IMAP is
refused because a writer is busy, and nothing says when to ask again. Right after a send,
the client's own sync of Sent and a second reader of Sent collide this way. Suggested: serve
the cached list while a sync runs, or answer with `Retry-After`.

**2. `dkimValid` is null in every body a mirror fetches.** `getBody` copies the DKIM verdict
only when it is already cached (`MessagesController.php:253-255`); the verification itself
is the separate `GET /api/messages/{id}/dkim` (`:298`). The web client shows **Unsubscribe**
only when `dkimValid` is true, so a mirror that wants the same gate has to make one extra
request per message. Suggested: verify when the body is built (the verdict is cached
server-side already), or put it on the envelope.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

## M-12

**Title:** Sieve and settings routes: three wrapping conventions, an HTML 500, and a trusted
address that disappears

**Body:**

**1. Three Sieve routes, three conventions.** With ManageSieve on, `GET
/api/sieve/active/{id}` answers bare `{"scriptName", "script"}`; `GET /api/filter/{id}`
answers a bare array; `GET /api/out-of-office/{id}` answers the `{"status","data"}` envelope
around `{"state": …|null, "script", "untouchedScript"}`, where `state` is null until the
settings were ever saved. With ManageSieve off, all three answer the envelope. A client
modelled on one recording reads every script as nil or fails every filter list on the other.

**2. With ManageSieve off, the filter routes answer an HTML 500.** `GET`/`PUT
/api/filter/{accountId}` answer the full Nextcloud HTML error page, while the sibling routes
answer a clean 400 `{"status":"fail","data":{"message":"ManageSieve is disabled"}}`.

**3. A trusted address hides while its domain is trusted.** Trust `example.org`, then
`someone@example.org`: both `PUT /api/trustedsenders/…` answer 201, and `GET
/api/trustedsenders` lists only the domain. Removing the domain brings the address back. A
settings list that mirrors the listing cannot show, or delete, the individual entry.

**Suggested fix:** the envelope for all three Sieve routes; catch the same
`ClientException` in the filter routes and answer the siblings' 400; list both trusted
entries.

The 422 that `PUT /api/sieve/active/{id}` answers for a script that does not parse, with the
parser's line and column in `message`, is exactly right, and is what a native form shows.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

## M-13

**Title:** OAuth account setup: let a native client observe completion

**Body:**

The provider redirects to `oauthRedirect` on the user's Nextcloud
(`lib/Controller/GoogleIntegrationController.php:80`,
`MicrosoftIntegrationController.php:84`), which stores the token and renders a done page
whose script tells its opener: `window.opener.postMessage('DONE')`
(`src/main-oauth-popup.js:22`).

A native client opens the consent page in `ASWebAuthenticationSession` (or the system
browser). That session completes only on a navigation to a callback scheme or an associated
domain, and the done page never navigates onward, so the client cannot observe completion.
Ours polls `GET /api/accounts/{id}/test` every 2 s for up to ten minutes, and cannot tell a
denied consent from a slow user.

**Suggested fix:** accept an allow-listed custom-scheme return URL when the client starts
the flow, and have the done page navigate to it after storing the token, with an error
parameter when consent was denied.

Version: Mail 5.12.0-rc.1 on Nextcloud 36.

---

# For `nextcloud/server`

All three were found by a native client using CalDAV and CardDAV on Nextcloud 36.0.0 dev
(dav 3.0.0-dev.1), measured against the live server.

## S-1

**Title:** CalDAV: a PUT refused with `no-uid-conflict` has already sent the scheduling REPLY

**Body:**

Scheduling delivers a same-server invitation into the attendee's default calendar as
`sabredav-<uuid>.ics`. An attendee client that writes its answer under its own resource name
gets **409 `no-uid-conflict`**, which is correct, but by then the organiser's copy has
already changed and a REPLY sits in the organiser's schedule inbox. Sabre's scheduling
handles the object before `CalDavBackend` reaches its UID check
(`apps/dav/lib/CalDAV/CalDavBackend.php:1546`).

Reproduction: an organiser invites a same-server attendee; the attendee PUTs a copy of the
event with the same UID, `PARTSTAT=TENTATIVE`, under a new name. Result: 409, the attendee's
copy is unchanged, and the organiser's copy shows the attendee as TENTATIVE. The client's
follow-up write onto the existing copy then sends a second, identical REPLY.

So a refused request has a side effect, and organiser and attendee can disagree about the
attendee's answer.

**Suggested fix:** check UID uniqueness before scheduling, or roll the scheduling back when
the write is refused.

## S-2

**Title:** CalDAV scheduling: the REPLY drops the attendee's comment

**Body:**

The web Calendar (and our client) writes the participation comment as
`X-RESPONSE-COMMENT` on the ATTENDEE line and as a COMMENT property. The attendee's copy
keeps both. The REPLY delivered to the organiser's schedule inbox, and the organiser's copy
it updates, carry PARTSTAT and CN only, so the organiser never sees "See you there" for a
same-server invitation.

**Suggested fix:** carry `X-RESPONSE-COMMENT`, and COMMENT per RFC 5546 §3.2.3, into the
REPLY.

## S-3

**Title:** Three DAV gaps a syncing client meets: no sync for "Recently contacted", a strong
ETag on a converted vCard, and two missing properties

**Body:**

**1. "Recently contacted" refuses `sync-collection`.**
`/remote.php/dav/addressbooks/users/{u}/z-app-generated--contactsinteraction--recent/`
lists no `sync-token` (404 in PROPFIND), and a `sync-collection` REPORT answers **415**
`Sabre\DAV\Exception\ReportNotSupported`. Multiget works. A client has to re-list the
whole book by ETag on every pass. Suggested: sync support for the contactsinteraction
address book (`apps/contactsinteraction/lib/AddressBook.php`), which already keeps per-card
ETags.

**2. A vCard 4.0 PUT answers a strong ETag, then is served as 3.0.** The ETag is
`md5($cardData)` of the bytes sent (`apps/dav/lib/CardDAV/CardDavBackend.php:655` and
`:723`), and a later GET serves sabre-normalised vCard 3.0. RFC 6352 §6.3.2.3 says a server
that does not store the representation as sent must not answer a strong ETag for the PUT. A
client that trusts it believes it holds the server's bytes. Suggested: no ETag, or a weak
one, when the stored or served form differs from the request.

**3. Two properties a client has to probe around.** `schedule-default-calendar-URL` answers
404 on the schedule inbox, where RFC 6638 §9.2 puts it, and 200 on the principal. The
birthday calendar is read-only but answers `oc:read-only` 404
(`apps/dav/lib/CalDAV/Calendar.php:375-376` reads it only from calendar info the birthday
calendar does not set); only `current-user-privilege-set` without `write-content` tells.
Suggested: answer the property on the inbox too, and set `oc:read-only` on the birthday
calendar as on shared read-only ones.

---

# For `nextcloud/circles`

## C-1

**Title:** Members API: a group member is reported as a team, and the level route takes
`{level}` instead of `{value}`

**Body:**

Against Circles 36.0.0-dev:

`POST /ocs/v2.php/apps/circles/circles/{id}/members {"userId":"admin","type":2}` adds the
group `admin`. `GET …/members` then reports it with `userType` **16** (team), with the
group only visible in `basedOn.source` 2. A user and a group with the same name are two
members whose `userId` is the same string, and a client cannot tell them apart without
reading `basedOn`.

Separately, every setter takes `{value}` (`name`, `description`, `config`) except `PUT
…/members/{memberId}/level`, which takes `{level}` and ignores `value`.

**Suggested fix:** report the type the member was added as, or document `basedOn.source` as
the field to read; accept `value` on the level route like its siblings.

---

# For `nextcloud/contacts`

## K-1

**Title:** The contact panel's shared items need `related_resources`, and say "No shared
items" when it is absent

**Body:**

The contact details panel's "Media shares / Talk / Calendar / Deck with you" calls `GET
/ocs/v2.php/apps/related_resources/related/account`. `related_resources` is not shipped with
the server; on a server without it the route answers OCS 998 "Invalid query", the panels
hide themselves, and the contact shows "No shared items with this contact" even for a user
with whom files are shared.

**Suggested fix:** fall back to the `files_sharing` listings (`shared_with_me` and `shares`,
which every server has) when `related_resources` is absent, or say that the panel needs the
app.

Version: Contacts 8.10.0-dev on Nextcloud 36.
