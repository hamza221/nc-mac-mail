<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# UX specification

*Screen by screen, including the states people actually hit. Component signatures are in
[../reference/ui-components.md](../reference/ui-components.md).*

## Window

One `NavigationSplitView`, three columns, the macOS shape every mail client uses.

```
┌───────────────┬──────────────────────┬──────────────────────────────────┐
│ SIDEBAR       │ MESSAGE LIST         │ MESSAGE                          │
│ 200–320       │ 280–480              │ remaining, min 420               │
│               │                      │                                  │
│ ▾ Work        │ ○ Sookie St. James   │ The Dragonfly opening menu       │
│   Inbox    7  │   The Dragonfly…  3m │ ● Sookie St. James  ·  14:22     │
│   Sent        │ ● Michel Gerard      │ to Lorelai Gilmore               │
│   Drafts      │   Front desk rota 2h │ ──────────────────────────────── │
│   Archive     │   Luke Danes         │ I moved the risotto to the       │
│   Junk        │   Re: coffee     Tue │ second course, tell me what…     │
│   Trash       │                      │                                  │
│ ▾ Personal    │                      │ 📎 menu.pdf  179 KB              │
│   Inbox    2  │                      │                                  │
│ ─────────────  │                      │                                  │
│ ⟳ 12,431/48,902                     │                                  │
└───────────────┴──────────────────────┴──────────────────────────────────┘
```

Column widths persist, approximately: SwiftUI's `navigationSplitViewColumnWidth(min:ideal:max:)`
has no binding that reports back what a drag resized a column to, so WS-13 tracks each
column's rendered width with a `GeometryReader` and feeds it back in as the next launch's
`ideal`. It is a measurement, not a restoration the framework promises, and it was not
verified against a live drag in this environment (no GUI). Collapsing the sidebar is the
system's behaviour, not ours. Window size and the sidebar selection restore on launch — state
restoration, not a preference.

### What the sidebar can select (WS-25)

One selection drives the content and detail columns. It is a `SidebarSelection`:

| Selection | Content column | Detail column | Built by |
| --- | --- | --- | --- |
| `.mailbox(id)` | that mailbox's messages | the message | v1 |
| `.unifiedInbox` | every account's Inbox, merged | the message | WS-28 / WS-29 |
| `.priorityInbox` | Important, follow-ups, then the rest | the message | WS-28 / WS-29 |
| `.favorites(inboxId:)` | the starred messages of that Inbox | the message | WS-28 / WS-29 |
| `.outbox` | the server outbox: scheduled and failed sends | the outbox message | WS-27 |
| `.contacts(sessionId:, scope:)` | the contact list of one login, `scope` = All, Favorites, one address book, one group, one team, Recently contacted ([ADR-0070](../decisions/0070-contacts-sidebar-section.md)) | the contact card | WS-35 |

Until the workstream in the last column lands, a selection it owns shows the content column's
placeholder (`ContentUnavailableView` naming what was picked) and an empty detail column; the
shell routes it, and the sync engine keeps running underneath.

**Restoring.** The selection is saved locally the moment it changes and comes back exactly on
the next launch — a contacts scope included. With nothing saved locally (a new Mac, a wiped
mirror), the window opens on the server's `start-mailbox-id` preference, the same one the web
client opens on; failing that, on nothing selected.

**The start mailbox.** After 5 seconds on a mailbox, Unified inbox or Priority inbox, that
choice becomes the server's `start-mailbox-id` (a mailbox's server id, or `unified` /
`priority`, as the web client writes it). It is a queued preference change, so it works
offline and is not written when the value is already the server's. Moving on within 5 seconds
writes nothing. Favorites, the outbox and contacts are never a start mailbox.

**Compose.** Every way of starting a message — New, Reply / Reply all / Follow up, Forward,
Edit as new, open a draft, open an outbox message, a smart reply, the Share extension — is a
`ComposeRequest` passed to `openComposer`, which opens one composer window for it (WS-27 builds
the window).

**Signing out** an account stops everything running for its login — mail sync, sending,
contacts, the calendar list, server state — before the Keychain item is gone from the session.
Choosing to remove local copies also deletes the login's contacts and settings mirror. The last
account signed out returns the window to the sign-in screen.

## Sidebar

`List(selection:)` with a section per account, in server `order`.

- **Account header** — `NCNavigationCaption(account.name)`. A trailing `action:` menu
  carries Refresh, Storage… and Sign out.
- **Mailbox row** — `NCNavigationItem(displayName, icon:, count: unread)`, nested in
  `DisclosureGroup` where the tree has children. Expansion state persists per mailbox.
- **Order** — special roles first, in the order people expect: Inbox, Drafts, Sent,
  Archive, Junk, Trash; then the rest alphabetically, case- and locale-insensitive.
  `MailboxTree` is a pure function and is unit-tested
  ([../delivery/testing-strategy.md](../delivery/testing-strategy.md)).
- **Unsubscribed mailboxes** are shown in secondary text with no mirror, because they still
  work, just without a local copy ([../decisions/0007-subscribed-mailboxes-only.md](../decisions/0007-subscribed-mailboxes-only.md)).
- **`\noselect` mailboxes** are container rows: expandable, not selectable.
- **Footer** carries, in priority order, whichever is true:
  1. backfill progress — `ProgressView` + "12,431 of 48,902";
  2. "Offline" when there is no route;
  3. "2 actions waiting" when the queue has visible failures, tappable to a popover;
  4. nothing at all when everything is fine. Idle chrome is noise.

**Context menu per mailbox:** Mark all as read, Refresh, Get info.

**Get info** opens a sheet (`MailboxInfoView`) that reads the mirror and nothing else, live,
so it moves while the backfill runs or the user triages:

- **On the server** — total and unread messages as of the last folder refresh
  (`mailbox.totalCount`, `mailbox.unreadCount`; the raw column, not the sidebar's local
  figure from [ADR-0060](../decisions/0060-unread-counts-come-from-the-mirror-once-complete.md)).
- **On this Mac** — mirror status (not mirrored; downloading the message list; downloading
  messages, *n* to go; complete), then messages mirrored, unread, bodies downloaded and,
  when any, bodies that could not be downloaded — counted from `message` rows by
  `MailStore.observeMailboxCounts(mailboxId:)` — and the last sync, relative.
- **When the last sync failed** — an `NCNoteCard(.warning)` with `lastSyncError` in plain
  words, how many times in a row it failed, and that the next sync retries. The stored error
  is never shown verbatim; an unrecognised one gets a generic sentence.

A mailbox whose last sync failed also carries a tooltip on its row pointing at Get info.

## Message list

`List(selection:)`, multi-selection enabled, windowed over the database.

Row is `NCListItem` with the Mail shape:

```swift
NCListItem(senderDisplayName, subtitle: subject) {
    NCAvatar(displayName: senderDisplayName, user: senderEmail, load: avatarLoader)
} details: {
    VStack(alignment: .trailing) {
        NCListItemDetails(date: sentAt, unreadCount: 0)
        HStack { presentStateGlyphs; threadCountBubble(.neutral); unreadBubble(.highlighted) }
    }
}
.fontWeight(row.threadUnreadCount > 0 ? .semibold : nil)
```

The counts share one line under the date. The first build put the unread bubble inside
`NCListItemDetails` and the thread count in `trailing:`, two columns at two heights.

- **Unread** is the semibold weight plus the counter bubble, matching the showcase. It is the
  *thread's* unread count, not the drawn message's `isSeen`, which is one rule for both views
  rather than two ([../decisions/0041-unread-is-the-threads-unread-count.md](../decisions/0041-unread-is-the-threads-unread-count.md)).
- **Avatar photo** from the mirror's `avatar` table, which the per-account `AvatarFetcher`
  fills from the server's avatar endpoint. Until a row exists `NCAvatar` draws coloured
  initials, and the photo replaces them when the row lands, with no request from the view.
- **Starred** shows `star`, **attachments** a clip, **answered** a reply arrow, on the
  trailing side and only when they apply. The first design put three fixed-width slots
  ahead of the avatar to keep rows aligned. In use, that was a blank column on nearly every
  row that pushed avatar and subject right, so QA moved the glyphs (2026-10-03).
- **Threaded view** shows the newest message of each thread with a count badge; flat shows
  every message. Toolbar `Picker`, remembered once for the app rather than per account
  ([../decisions/0040-list-view-is-remembered-per-app.md](../decisions/0040-list-view-is-remembered-per-app.md)).
- **Date grouping** — Today / Yesterday / This week / Earlier as section headers. Cheap,
  and it is how people navigate a long list.
- **Sort** is newest first, and does **not** yet follow the account's server-side
  `sort-order` preference. Nothing persists that preference — `SyncScheduler` reads it and
  keeps it in memory ([../decisions/0036-sort-order-decides-the-cursor.md](../decisions/0036-sort-order-decides-the-cursor.md))
  — and the store's list queries are `ORDER BY m.sentAt DESC` with the index that makes them
  fast. Making the two clients agree needs a column on `account` and an ordering parameter on
  `observeMessages`; WS-08's report carries the request.
- **Selection** — click selects, ⇧-click extends, ⌘-click toggles. Toolbar and context menu
  act on the whole selection.

**States**

| State | What is shown |
| --- | --- |
| Mirrored, has messages | The list |
| Mirroring, first page in | The list, growing. No spinner |
| Mirrored, empty mailbox | `ContentUnavailableView("No messages", …)`, with the icon through `MailSymbol` |
| Search, no hits | `ContentUnavailableView.search` with the query |
| Mailbox unselectable | Never reachable: the row does not select |
| Never mirrored, offline | "Not downloaded yet" plus what will happen on reconnect |

## Message view

Native chrome, WebView body ([../architecture/rendering.md](../architecture/rendering.md)).

```
Subject                                                    .title2, semibold
● Sender Name <sender@example>                 14:22       NCUserBubble, .medium
to Lorelai Gilmore, Michel Gerard  ▾                       NCChip each, collapsed past 3
───────────────────────────────────────────────────────────
[ NCNoteCard .warning — remote content blocked ]           only when applicable
───────────────────────────────────────────────────────────
  body
───────────────────────────────────────────────────────────
📎 menu.pdf 179 KB   📎 rota.ods 22 KB     [Save all]      only when applicable
```

- **Toolbar**: Archive, Delete, Junk, Move ▾, Star, Mark unread, Refresh. `NCButtonStyle.icon`
  with `.help` tooltips carrying the shortcut.
- **Thread** — siblings listed below, collapsed, newest last, with the selected one
  expanded. Clicking a sibling expands it in place; it does not navigate.
- **Phishing and security** — a `NCNoteCard(.error)` when the server's `phishingDetails`
  says so; a small verified badge for a valid DKIM or S/MIME signature. Absent when there
  is nothing to say. A permanent green badge teaches people to ignore badges.
- **Attachments** — a row of chips; click downloads through a save panel; images preview in
  Quick Look.

**States**

| State | What is shown |
| --- | --- |
| Body mirrored | The message |
| Body not mirrored, online | Header immediately, body placeholder for the moment it takes; the fetch is queued at the head |
| Body not mirrored, offline | Header, and "This message has not been downloaded yet. It will be available when you are back online." |
| Body fetch failed | The same, plus Retry |
| Nothing selected | `ContentUnavailableView("No message selected")` |

Note the shape of the second row: the header is always available, because the envelope is
always mirrored. The app never shows an empty screen where a message should be.

## Search

`.searchable` on the message list, ⌘F.

- Results replace the list, as you type, from the local index — no debounce theatre beyond
  the one frame it takes.
- Scope control: **This mailbox** / **All mail** (across accounts).
- Matches highlighted with `NCHighlightText`.
- Result rows carry the mailbox name, since "all mail" spans folders.
- Footer states the coverage while the backfill is incomplete: "Searching 31,204 of 48,902
  downloaded messages." Honest, and it disappears when the mirror completes.
- Escape clears and returns to the mailbox.

## Composer editor (WS-20)

The rich text editor the composer (WS-27) embeds. A TextKit 2 `NSTextView` that serialises
to the fixed HTML tag set itself ([ADR-0065](../decisions/0065-native-rich-text-editor.md),
[ADR-0073](../decisions/0073-editor-canonical-html.md)); the §6.5 checklist rows are the
parity target. The editor owns no mail types and no network: HTML comes in through
`HTMLImporter` and leaves through `HTMLSerializer`, and nothing in between can fetch.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Paragraph ▾  Font ▾  13 ▾ │ B I U S │ A⃞ ▨ x₂ x² │ 🖼 │ ≡▾ ⇥ ⇤ │ • 1. ❝ │
│ 🔗  ⌫fmt  🔍  </>  ↶ ↷                                                   │
├──────────────────────────────────────────────────────────────────────────┤
│ The quarterly numbers are in — see the chart below.                      │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Modes.** `EditorDocument.mode` is `.plain` or `.rich`. Which one a new message starts in
is the account's writing mode — wired by WS-27/WS-39, not here. Turning formatting on is
instant. Turning it off while the document carries any formatting asks first: "Turn off
formatting" — **Turn off and remove formatting** / **Keep formatting** — because the
strip is destructive. In plain mode the toolbar shows Undo/Redo only and typing attributes
are pinned to the base font.

**Toolbar** (rich mode, every control labelled for VoiceOver, shortcuts in `.help`):

| Control | Behaviour |
| --- | --- |
| Paragraph style | Menu: Paragraph, Heading 1–3 → `p`, `h1`–`h3` |
| Font family | Menu: Default + the web client's list (Arial, Courier New, Georgia, Lucida Sans Unicode, Tahoma, Times New Roman, Trebuchet MS, Verdana) → `span[style=font-family]` |
| Font size | Menu: Default, 9–24 → `span[style=font-size]`, px |
| B / I / U / S | `strong`, `em`, `u`, `s`; reflect the selection's state |
| Text colour / background | `ColorPicker`s → `span[style=color]`, `span[style=background-color]` |
| Subscript / superscript | `sub`, `sup`, mutually exclusive |
| Insert image | Open panel (png/jpeg/gif/bmp/webp, >10 MB refused) → `img[src=data:…]`, embedded base64, width kept in the HTML |
| Alignment | Menu: left, centre, right, justify → `text-align` on the paragraph |
| LTR / RTL | `dir` on the selected paragraphs |
| Lists | Bulleted / numbered → `ul`/`ol` + `li`; toggling again lifts back to paragraphs |
| Quote | `blockquote` around the selected paragraphs |
| Link | Popover with a URL field; applies to the selection, inserts the URL as text when there is none |
| Remove format | Strips inline formatting, keeps blocks |
| Find and replace | `NSTextFinder` find bar with replace, incremental |
| Source | Swaps the editor for an editable HTML text view; toggling back re-imports through `HTMLImporter`, accepting the canonical-form loss |
| Undo / redo | The view's `UndoManager`; formatting operations register their inverse |

**Triggers**, typed at a word boundary (start of paragraph or after whitespace):

- `:` opens the system emoji palette (`NCEmojiPalette`). The palette inserts at the caret;
  when an emoji lands right after the trigger the colon is removed, and typing anything
  else — including Space — cancels and keeps the colon
  ([ADR-0074](../decisions/0074-editor-triggers.md)).
- `@` mention, `!` text block, `/` Smart Picker: one session API. The characters typed
  after the trigger are the query; a popover anchored at the caret lists what the
  `MentionProvider` / `TextBlockProvider` / `SmartPickerProvider` returns (implemented by
  WS-26/WS-27; without a provider the trigger is inert). Choosing a row replaces the
  trigger and query: a mention becomes a `mailto:` link and is reported through
  `onMention` so the composer can add the address to To; a text block inserts its HTML
  through the importer; a Smart Picker row inserts a titled link. Escape, Space or moving
  the caret out of the session cancels.

**Paste and drop.** The readable pasteboard types are plain text, RTF, RTFD, images, HTML
and file URLs — nothing else. HTML goes through `HTMLImporter` only, never
`NSAttributedString(html:)`, so pasting never makes a network request; RTF is normalised
to the attribute set the serialiser understands (pasted fonts and sizes survive, per
§6.5). Pasted or dropped files — including screenshots off the pasteboard — become
attachments through the `onFileDrop` callback, not inline content. In plain mode only
plain text is readable.

**Out of editor scope** (owned elsewhere, listed so reviewers do not look for them here):
the composer window and fields (WS-27), "Insert image from Files" (WS-33 via WS-27),
account writing-mode default and signature handling (WS-27/WS-39), the ~300 ms live
source-sync of the web client — the native source view syncs on toggle instead.
Interactive image resize handles are not in v2's editor; width survives the round trip and
is the serialised unit (library feedback records the TextKit 2 gap).

## Settings

`Settings` scene, `Form` + `.formStyle(.grouped)`, three tabs.

**General** — default list view (threaded/flat), mark-as-read delay, appearance note.

**Accounts** — one row per account: name, address, mirror state, last sync, Sign out. A
note that accounts are added in the web client, with a button that opens it, because a
blank space where account creation should be is worse than an explanation.

**Storage** — the panel [ADR-0008](../decisions/0008-no-automatic-eviction.md) requires:

```
Work · lorelai@dragonfly.example
  48,902 messages · 812 MB local · mirror complete
  [Remove local copies]  [Re-download]  [Check for missing messages]

Personal · lorelai@example.com
  3,204 messages · 61 MB local · downloading bodies (2,104 remaining)   [Pause]
```

Every destructive confirmation says it removes **local copies only** and does not touch the
server.

## Keyboard

Matching the web client where it costs nothing, since people use both.

| Key | Action |
| --- | --- |
| `↑` `↓` | Move selection in the list |
| `←` `→` | Previous / next message |
| `A` | Archive |
| `S` | Toggle star |
| `U` | Toggle unread |
| `J` | Junk |
| `⌫` | Delete (trash, or erase when in trash) |
| `R` | Refresh |
| `⌘F` | Search |
| `⌘⇧F` | Search all mail |
| `⌘P` | Print message |
| `⇧` + click | Extend selection |
| `Space` | Scroll the message body |
| `⌘,` | Settings |

Registered as `Commands` so they appear in the menu bar with their shortcuts — a shortcut
that exists only in a `keyboardShortcut` modifier is undiscoverable.

## Errors, and the rule about them

One rule, and it is the difference between a calm app and a nervous one:

> **Nothing that the app can retry gets a dialogue.**

- Offline → one sidebar indicator. Not a banner, not a sheet.
- Sync failure on one mailbox → that mailbox's row shows it on hover, and Get info explains.
- Queued actions failing → one aggregate indicator after five attempts, "N actions waiting",
  with a **Retry** button that clears every backoff and drains at once
  ([../architecture/offline-queue.md](../architecture/offline-queue.md)).
- Local mirror unreadable at launch → one alert, because the session would otherwise
  silently run on an empty copy: **Delete and Download Again** (deletes the file and
  relaunches), **Continue Without Saving**, or **Quit**.
- Authentication lost (401) → this one **is** modal, because nothing works until it is
  fixed: "Your session has expired. Sign in again."
- Disk full → surfaced once in the storage panel with the number of bytes needed.

## Accessibility

- Every control has a label; decorative icons are marked decorative. The library makes this
  mandatory at the type level.
- Full keyboard navigation, visible focus, no mouse-only affordance.
- VoiceOver rotor works over the list, and a row reads as "unread, from Sookie St. James,
  The Dragonfly opening menu, 3 minutes ago".
- Dynamic Type throughout the native chrome; the message body keeps its own sizing, with
  ⌘+/⌘− to zoom it.
- Reduce Motion honoured; Increase Contrast honoured through the library's contrast maths.
- Nothing is conveyed by colour alone: unread is weight plus a bubble, starred is a glyph.
