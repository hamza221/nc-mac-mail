<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Upstream issue drafts

*Ready for a human to post. Nothing here was filed by an agent.*

Thirteen drafts: six against
[`hamza221/nextcloud-swiftui`](https://github.com/hamza221/nextcloud-swiftui), six against
[`nextcloud/mail`](https://github.com/nextcloud/mail), and one that goes to the security
inbox rather than to a public tracker.

Each draft is a title and a body. The evidence behind each one, with the call sites, is in
[library-feedback.md](library-feedback.md) and [server-findings.md](server-findings.md).

**Before posting.** Read L-6 and M-4 first: L-6 asks for a CI job rather than a code change,
and M-4 is a privacy report that should not be a public issue.

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

## L-2

**Title:** `NCListItem`: a list row needs an accessory column before the leading slot

**Body:**

`NCListItem(_:subtitle:leading:details:trailing:)` gives a row one leading view
(`Components/ListItem/NCListItem.swift:79`). A mail row needs four things there: an unread
dot, a star and an attachment clip, each optional, and then the avatar.

Predicted from the signature during a design pass, then hit for real while building the
message list, so this is two independent sightings of the same gap.

**What a caller has to do.** Build `HStack { threeFixedSlots; NCAvatar(...) }` inside the
leading slot and size the slots by hand from `theme.metrics.icon.small` and
`theme.metrics.spacing.hairline`. Every absent glyph has to be a `Color.clear` of that
size, because without a fixed width a row with no glyphs puts its avatar two points left of
a row with one, and a list scanned vertically stops lining up.

It works and it is twenty lines. The twenty lines are the library's own alignment
reimplemented by a caller who cannot see the library's spacing decisions, which means three
Nextcloud apps will line their rows up three slightly different ways.

**Suggested fix:** an `accessories:` slot ahead of `leading:`, laid out by the component at
a width it picks from the metric scale. Files wants the same shape for shared, favourite and
locked. Talk wants it for unread and mention markers.

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
