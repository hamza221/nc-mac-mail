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

## Sidebar and mailbox management (WS-28)

Supersedes the v1 "Sidebar" section above where the two differ. Every rule is §3 of the web
client's QA checklist (nextcloud/mail#13797), mapped to a native sidebar. The sidebar reads
the store and nothing else; every folder change is a queued operation, so it works offline and
appears at once; remove account, repair and delegation are online-only commands
([ADR-0068](../decisions/0068-settings-commands.md)) whose outcome is the only thing awaited.

**Top.** A "New message" button above the list opens the composer
(`ComposeRequest.new(accountId: nil, mailto: nil)`).

**Order of the list.**

1. **Priority inbox** — always. **All inboxes** — only with more than one account; its count
   is the sum of every Inbox's unread. Both are `SidebarSelection` values, never folders.
2. **One section per account**, in account order. The caption is the account's email address.
   - Folders, as v1's tree. Under each top-level Inbox, a **Favorites** row (star) that selects
     `.favorites(inboxId:)`. It has no count.
   - **Folder collapse.** Inbox, Drafts, Sent and Trash (by role, or the account's configured
     drafts/sent/trash folder) are always visible. When more than one *other* top-level folder
     exists, the rest hide behind a last row: "Show all folders" ("Show all subscribed folders"
     when the account shows only subscribed folders) / "Collapse folders". Collapsed is the
     default, as on the web; the choice persists per account.
   - **Show only subscribed folders** removes unsubscribed folders from the tree.
   - **Counts.** A folder's unread count; a folder whose subfolders hold unread mail adds a
     second, outlined count with the subfolders' total ("3 (5)" on the web). No count on Trash.
   - **Names and icons.** Top-level special folders show translated names (Inbox, Drafts, Sent,
     Trash, Junk, Archive, All) whatever the server calls them; the snooze folder gets a clock,
     a shared folder a shared-folder glyph.
   - **Connection failed.** When the account's connection test (run once per account when the
     sidebar starts, `SettingsCommands.testConnection`) says the server cannot be reached with
     the stored credentials: a warning row "Connection failed. Please verify your information
     and try again" with a "Change password" button that opens Settings on Accounts. The
     folders stay listed — they are the mirror, readable offline.
   - **Provisioned and disabled** ([ADR-0086](../decisions/0086-a-provisioned-account-that-cannot-connect-is-disabled.md)):
     a provisioned account whose connection test fails shows no folders, only the row
     "Provisioned account is disabled"; its account menu holds only the explanation "Please
     login using a password to enable this account. The current session is using passwordless
     authentication, e.g. SSO or WebAuthn."
3. *(Contacts section slot — WS-35.)*
4. **Outbox** with its count, only while `outboxMessage` has rows (`.outbox`).
5. **Mail settings** opens the Settings window.

**Account menu** (the caption's trailing ⋯):

- "Used quota: 42 % (10 GB)" from the account's `serverResult` quota row (requested when the
  sidebar starts and on Refresh); "Used quota: 42 %" from `account.quotaPercentage` when the
  server gave no limit; nothing when neither says anything.
- Refresh. Account settings… (Settings → Accounts). Storage… (v1).
- Delegate account… — not for a delegated or provisioned account. A sheet listing the account's
  delegates (mirrored), each with Revoke (confirmation "Revoke access?" / "{user} will no
  longer be able to act on your behalf"); "Add delegate" takes a Nextcloud user ID and
  "Delegate access" runs the command. Errors: "Could not delegate access" / "Could not revoke
  delegation", with the server's message when it sent one.
- Show only subscribed folders — a checkmark toggle, queued (`patchAccount`).
- Add folder… — an alert with "Folder name"; Create queues `createMailbox` at the top level.
  An empty name, or one containing the account's hierarchy delimiter, is refused with
  "Unable to create mailbox. The name likely contains invalid characters. Please try another
  name."
- Move up (not on the first account) / Move down (not on the last): every account gets its new
  position as a queued `patchAccount(order:)`, so the order persists and syncs.
- Remove account… — not for a provisioned or delegated account. Confirmation "Remove account"
  / "The account for {email} and cached email data will be removed from Nextcloud, but not
  from your email provider." / "Remove {email}". Failure: "Could not delete account".
- Sign out (v1).

**Folder menu** (context menu on a real folder; a virtual entry or a synthetic container has
none). Rights follow the server's `myAcls`; a server without ACL support allows everything.

- Info line: "{total} messages" or "{unread} unread of {total}"; "Loading …" before the first
  folder refresh reported a total.
- Mark all as read [s] — queued `markMailboxRead`.
- Add subfolder… [delimiter, k] — alert "Folder name"; queues `createMailbox` with
  `parent<delimiter>name` and expands the parent.
- Rename… [no subfolders, x] — alert pre-filled with the folder's name; queues
  `renameMailbox`. Enqueue failure: "An error occurred, unable to rename the mailbox."
- Move folder… [not special, delimiter, no subfolders, x] — a sheet "Choose target folder":
  the top level ("/") and every folder with right k, except itself; "Move" queues
  `moveMailbox`.
- Repair folder — `SettingsCommands.repairMailbox`; on success the folder is refreshed. A 429
  shows "Please wait {n} minutes before repairing again", {n} from `Retry-After` (10 when the
  server sent none), and Repair stays disabled for that folder until then.
- Subscribed — checkmark toggle, queued `setMailboxSubscribed`. Sync in background — checkmark
  toggle, not on Inbox, queued `setMailboxSyncInBackground`.
- Delete all messages… [t, e] — confirmation "Clear mailbox {name}" / "All messages in mailbox
  will be deleted." / "Clear folder"; queued `clearMailbox`.
- Delete folder… [not special, no subfolders, x] — confirmation "The folder and all messages in
  it will be deleted."; queued `deleteMailbox`; if the folder was selected, the selection moves
  to Priority inbox.
- Refresh, Get info (v1).

"Clear cache" is a debug-only web tool and excluded ([ADR-0064](../decisions/0064-v2-parity-scope.md)).

**Drag and drop (§3.4).** The message list drags a `MessageDragPayload` (local message ids,
source mailbox, account; UTType `com.nextcloud.mail.message-drag`). A folder row accepts it
when it is selectable, in the same account, not the source folder, not Drafts or Sent, and has
right i; it highlights while targeted and moves the rows through the triage move (thread or
message per the list view, with undo). Hovering a drag over "Show all folders" or a collapsed
parent expands it for the drag; the collapsed state comes back after the drop.

**Errors.** Queue failures after the fact use the footer's "actions waiting" (v1). Commands
show their failure in an alert, with the server's message when there is one.

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

## Search filters (WS-32)

v1's instant search stays exactly as it is; the filters refine it. Everything runs on the
local index (`messageSearch` FTS5 + `message` columns) — no server search call, online or
off.

**Filter bar.** A row under the toolbar, shown while the search field is active or any filter
is on:

- Three toggle chips (`NCChip`, `.primary` when on): **Has attachment**, **Unread**,
  **To me**. "To me" means a `To:` recipient is the message's account address or one of
  that account's aliases.
- **Search parameters…** opens the sheet; its label carries the number of active parameters.
- **Clear** resets every chip and parameter (shown only when one is on). Escape in the field
  clears the text, as before; the filters stay until cleared, so the bar stays visible.

**Search parameters sheet.** A form, applied when **Search** is pressed (Cancel discards):

| Field | Meaning |
| --- | --- |
| Subject | Words in the subject only (same prefix/phrase rules as the field) |
| Body | Words in the downloaded body only |
| Date range | Optional start and end day, both inclusive, local calendar |
| From | **One** address; entering another replaces it |
| To / Cc / Bcc | Any number of addresses each; a message matches if it has **any** of them in that field |
| Tags | Any number; a message matches if it carries **any** of them |
| Important, Favorite, Has attachments, Mentions me | Toggles ("Has attachments" is the same filter as the chip) |

Address fields take an address typed and confirmed with Return, suggesting addresses already
seen in mirrored mail as you type. Every address match is exact and case-insensitive.

**Rules.**

- Different filters combine with AND; values within one field combine with OR.
- A search term needs at least two characters; shorter terms are ignored (in the field,
  Subject and Body alike). One character typed with no filter on leaves the mailbox showing.
- Filters without any text are a search too: results are then newest first. With text they
  stay ranked by relevance (subject and people above body), ties newest first.
- The scope control (This mailbox / All mail) applies to filters exactly as to text.
- Empty result: the list's generic no-results state.

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

## People: suggestions, bubbles and the contact card (WS-26)

Implements [ADR-0072](../decisions/0072-local-first-autocomplete.md). Everything here reads
the mirror; the only network effects are a queued `contactPut` and the ADR-0067 autocomplete
supplement, both written to the store by engines.

**Recipient suggestions** (`RecipientSuggestionProvider`, consumed by the composer's chip
fields and the editor's `@` mentions).

- Typing yields local results immediately, from four sources: the contacts mirror (every
  enabled address book, the system book included; people and groups), the login's own
  identities (account addresses and aliases), and every address seen in mirrored mail.
- Ranking, top to bottom: contacts and contact groups by most recent interaction (the
  newest mirrored message carrying one of their addresses; never-mailed contacts follow,
  by name); then mail-derived addresses by frequency (messages carrying them), newest
  first on ties; then the server supplement's extra rows; own identities last.
- Dedup by address, case-insensitively: an address appears once, under its best source.
  An own identity is always shown as an identity (last), even when the system address book
  also lists it.
- At two or more characters, `GET /api/autoComplete?term=` is requested after the local
  list is shown. Its rows land in `recipientSuggestion` and are merged in as they arrive:
  the list may grow, it never reorders what was already shown above the server rows.
  Offline the request is skipped and the cache from an earlier identical term is used.
- Matching: every typed word must prefix a word of the name, nickname or organisation, or
  appear inside the address. At most 20 suggestions.
- A contact group expands to its mirrored members' first addresses when picked; a server
  group (`nextcloud:<gid>`) is kept as one recipient and the server expands it on send.
- `@` mentions use the same local list, addresses only.

**Recipient bubble** (`RecipientBubble`, parity §5.11) — a person chip (avatar + name, the
address when there is no name) used wherever a person appears in the message header. A click
opens the contact card as a popover.

**Contact card** (`ContactCardPopover(email:)`)

```
              (avatar)                         NCProfileCard, centred
           Lorelai Gilmore                     .headline
         lorelai@example.com                   .secondary
       Dragonfly Inn · Contacts                organisation · address book, when a contact
       [Reply]  [Copy address]
  [Add to contact…]  [New contact…]            only when no contact carries the address
```

- Contact match: the enabled-book contacts carrying the address. Matched: name,
  organisation and book shown; Add/New hidden.
- **Reply** opens a new composer to the address (`ComposeRequest.new` with a `mailto:`).
- **Copy address** puts the bare address on the pasteboard.
- **Add to contact…** — a search field over writable-book contacts (people, not groups),
  results as you type; picking one appends the address as an `EMAIL` and queues a
  `contactPut`. Works offline: the card updates at once, the write drains later.
- **New contact…** — name (prefilled from the label) and address book (writable, enabled;
  the login's own default book first); Create queues a `contactPut` that creates
  `<UID>.vcf`.
- Nothing in the card waits on the network; an engine-less login (signed out) disables the
  two write actions with an explanatory help tooltip.

**Recent mail with a contact** (`RecentMailList(email:sessionId:)`, the contact detail
pane) — the newest 20 mirrored messages of that login with the address in From/To/Cc/Bcc,
one per message (not per mailbox copy), each row: subject, the other party, date. Empty:
"No mail with this address yet." Click selects the message's mailbox.

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

## Triage v2: tags, snooze, quick actions, pickers, shortcuts (WS-31)

Everything here acts on the same `Selection` v1's triage does (one row = one thread in the
threaded view), goes through `MutationQueue` and nothing else, and therefore works offline
exactly as online. Undo is `⌘Z` on the triage `UndoManager` (ADR-0051).

**Where the actions live.** Every action is a menu-bar item in **Message** (so it has a key
or can be given one), and the same items appear in the list's context menu and — for the
§4.5 header "…" — in the toolbar's **More ▾** menu. Sheets (tags, move, custom snooze) are
presented by the main window's `.triagePresentations` host, so the menu bar can open them.

**Tags (§4.8).** *Message ▸ Edit Tags…* opens a sheet titled "Tags" for every selected
message (threads expand to members).

```
Tags                                   [Done]
Add default tags
  ● Work            [Set tag]       …
  ● Personal        [Unset tag]     …
Add tag
  ● Later           [Set tag]       …
  [+ Add tag]  → "Tag name"  ⏎
```

- Order: default tags (`$label2`…`$label5`, i.e. `isDefaultTag`), then tags set on *every*
  envelope, then alphabetical. `$label1` (Important) and the hidden system tags (`forwarded`,
  `hasattachment`, `has_cal`, `has cal`, `hasnoattachment`, `notjunk`, `loadremoteimages`,
  `unsubscribe newsletter`, matched on lowercased display name) are never listed. `$follow_up`
  shows as "Follow up".
- A row shows **Unset tag** when every envelope has it, else **Set tag**; one press applies to
  all envelopes and the chips update from the store observation. Undoable: the inverse
  restores each message's own previous labels.
- **Add tag** creates with a random `#rrggbb` colour; validation inline (no toast):
  "Tag name cannot be empty", "Tag name is a hidden system tag", "Tag already exists". The
  new tag is a placeholder row (ADR-0081) and may be set on messages at once, offline.
- Row "…": **Edit name or color** (inline name field + `ColorPicker`, same validation) and
  **Delete tag** (non-default only) → confirmation "The tag will be deleted from all
  messages." Tag create/edit/delete are not undoable (the web confirms instead).

**Snooze (§4.4).** *Message ▸ Snooze ▸* with exactly these presets, computed from the local
clock and calendar at the moment the menu opens:

| Preset | Shown when | Fires at |
| --- | --- | --- |
| Later today – 18:00 | before 17:00 | today 18:00 |
| Tomorrow – Tue 08:00 | always | tomorrow 08:00 |
| This weekend – Sat 08:00 | Monday–Thursday | this Saturday 08:00 |
| Next week – Mon 08:00 | not on Sunday | next Monday 08:00 |
| Custom… | always | sheet: `DatePicker` (date + time, not before now) + "Set custom snooze" |

Times are on the hour exactly (the web keeps the current minutes through moment's
`hour()`; the checklist and this client say 18:00/08:00). Hidden when the selection is
already in the account's Snoozed mailbox; then **Unsnooze** is shown instead. If the account
has no snooze mailbox, the first snooze queues `createMailbox("Snoozed")` and
`patchAccount(snoozeMailboxId:)` before the snooze, all offline-safe; an existing mailbox
named "Snoozed" is reused instead of creating a second. Snooze is undoable (⌘Z unsnoozes);
unsnooze is not (the message is back where it came from).

**Spam (§4.4).** *Message ▸ Mark as Junk* (`J`) toggles like the web: when every selected
message is already `$junk` the item reads **Mark Not Junk** and does `junk=false,notjunk=true`
and moves messages in Junk back to Inbox; otherwise flags junk and moves to Junk. Both also
mark read and clear Important, as the web does. Undo restores flags and folders.

**Quick actions (§4.4, §8.7).** *Message ▸ Quick Actions ▸* lists the selected messages'
account's quick actions, filtered by ACL on the source mailbox (`myAcls`; absent = all
rights): spam/tag/important/favorite need `w`, read/unread need `s`, move/delete need `t`+`e`.
Steps run in order as queued operations, as one undo group. A tag step whose tag is gone
shows "Could not apply tag, configured tag not found"; a move whose mailbox is gone, "Could
not move thread, destination mailbox not found" (the remaining steps still run). Last item:
**Manage Quick Actions…** opens Settings. Disabled with "No quick actions" when empty.

**Move picker (§4.7).** *Message ▸ Move to Folder…* and the toolbar Move button open
"Choose target folder": a search field, breadcrumbs from "/", a list of the current level's
children (chevron drills in, breadcrumb goes back). Typing searches the whole tree and shows
full paths "Parent / Child". Empty states "No more submailboxes in here" / "No results".
Only folders with ACL `i` that are selectable are pickable; the source folder is a no-op.
Button **Move thread**/**Move message** is disabled until a folder is picked.

**Forward and edit as new.** *Message ▸ Forward as Attachment* →
`openComposer(.forward(messageIds:asAttachment: true))` for the whole selection;
*Message ▸ Edit as New Message* → `.editAsNew(messageId:)` (single message).

**Shortcuts (§2.6).** All registered as menu items; the composer ones are enabled only while
a composer window is key (WS-27 supplies the handlers through `FocusedValues`).

| Key | Menu item |
| --- | --- |
| `C`, `⌘N` | Message ▸ New Message, File ▸ New Message |
| `←` `→` | Message ▸ Previous / Next Message |
| `S` `U` `A` `J` `⌫` `R` | Star, Mark as Unread, Archive, Junk, Delete, Refresh |
| `⌘P` | File ▸ Print Message… |
| `⌘⇧D`, `⌘↩` | File ▸ Send (composer); second item "Send Now" for the web's Ctrl/Cmd+Enter |
| `⌘S` | File ▸ Save Draft (composer) |
| `⌃⌥1` `⌃⌥2` `⌃⌥3` | Format ▸ Heading 1/2/3 (rich composer) |
| `⌘F`, `⌘⇧F` | Find, Find in All Mail (search) |

`Enter`/`Space` on a thread header and `Esc` are focus-level, not menu commands (WS-30).
Help ▸ Keyboard Shortcuts lists the whole table.

## Message list v2: layouts, sections, adornments (WS-29)

Extends [Message list](#message-list); where the two disagree, this section is current.

**Layouts.** The server's `layout-mode` preference, as the web client spells it:

| Value | Window |
| --- | --- |
| `vertical-split` (default) | Three columns: sidebar, list, message |
| `horizontal-split` | Two columns: sidebar, then the list above the message in a resizable vertical split |
| `no-split` | Two columns: sidebar, then the list full width; opening a message (double-click, Return) replaces the list with the message and a Back button |

The selection lives in the list's model, not in a view, so switching layout keeps the
selected messages and the open message. `compact-mode` (`true`/`false`) drops the avatar to
small, the preview line and the adornment line, leaving sender, subject, date and glyphs on
two lines. All three preferences are written to the server through the queue's
`setPreference` kind (offline-safe), and read back from the mirrored preference rows of the
first signed-in login (lowest login id) — one window, one layout. Writing a preference
writes it to every signed-in login. The settings UI is WS-38's; the list carries a View
menu in its toolbar (Layout, Compact, Sort, Favorites on top) until it lands.

**Sort order.** `sort-order` `newest` (default) or `oldest`, queued as a preference like the
web client does — never kept locally. The list queries order by it; the mirror's cursor
semantics follow it on the next sync run (ADR-0036).

**Sections.**

| List | Sections, top to bottom |
| --- | --- |
| A mailbox, `sort-favorites` = `true` and the mailbox has starred messages | Favorites (starred, ungrouped), then the rest (not starred) in date groups |
| A mailbox otherwise | Date groups |
| Unified inbox (every account's Inbox, merged) | Favorites when `sort-favorites` is on, then date groups |
| Favorites (`.favorites(inboxId:)`) | The Inbox's starred messages, date groups |
| Priority inbox (every Inbox) | Favorites (starred; only when `sort-favorites` is on) · Follow up (tagged `$follow_up`, sent at least 4 days ago, any mailbox; only when `follow-up-reminders` is not `false`) · Important (`isImportant`) · Other (not important). With Favorites on, Important and Other exclude starred messages. No date groups. Empty sections are hidden. |

Follow up shows the result of `ServerStateMirror.checkFollowUps(messageIds:)` for the rows it
shows (`serverResult` kind `followUp`): a message whose reply has arrived
(`wasFollowedUp: true`) is dropped from the section before the queued tag removal lands.

**Date groups**, as the web client's `groupEnvelopesByDate`: Last hour, Today, Yesterday,
Last week (7 days), Last month (one calendar month back), then each earlier month of the
current year by name, then each earlier year. A message from a previous year is always in its
year's group, even when it is only a few weeks old (2 January shows December's mail under
"2025", not "Last month" — the web's rule, kept for parity). A future date (clock skew) is
"Last hour". With `oldest` first the groups run in reverse.

**Row adornments**, below the subject line, only when they apply and never in compact mode:

- **Tags** — one chip per tag, tinted with the tag's colour; `$label1` (Important, shown as
  a glyph) and the web client's hidden system labels are not shown, nor `$follow_up` inside
  Priority inbox, which has its own section.
- **Attachments** — up to three chips with the file name, then "+N", from the mirrored
  attachment rows; before a body is mirrored the clip glyph alone.
- **Preview** — the server's AI summary (`message.summary`, else a cached `threadSummary`
  server result), marked "AI summary", else the preview text.
- **Drafts** — the subject reads "Draft: …".
- **Important** gets its own glyph beside starred, answered and attachment.

**Hover.** Pointing at a row shows quick actions on its trailing edge: Star, Mark
read/unread, Archive, Delete, and a "…" menu (the right-click menu plus Open in New Window).
They act on that row only (WS-31's actions).

**Multi-select.** With two or more selected, a header above the list reads "N selected" with
Mark read, Mark unread, Star, Archive, Delete and Clear selection. `⌘A` selects every loaded
row of every section.

**Drag.** Rows drag as `com.nextcloud.mail.message-drag` (`MessageDragPayload`: the dragged
selection, or the row alone when it is not selected) onto sidebar mailboxes (WS-28). A
selection spanning mailboxes drags only the rows sharing the dragged row's mailbox.

**Open in New Window.** Context and "…" menu item: a message window
(`WindowGroup(id: "message", for: Int64.self)`) showing that message alone.

## Message view v2 (WS-30)

Parity with the web client's §5 (checklist rows 5.1–5.8, 5.10, 5.12), except calendar
(WS-34) and the contact card itself (WS-26, embedded here). Everything below reads the
mirror; the only things that reach the network are queue rows, `ServerResultFetcher.request`
and the one-shot `MessageExporter`, none of which hands a response to a view.

**Thread mode.** The detail column shows the whole conversation, oldest first, in one column:

```
[ Thread summary — NCNoteCard .info ]            ≥ 3 messages, summaries not known-off
Subject                                          thread subject, "No subject" fallback
● Michel   Re: lunch preview…          Mon 9:12  collapsed envelope (NCListItem)
● Michel   Encrypted message           Mon 9:40  collapsed, PGP/S-MIME encrypted
┌ Lorelai <lorelai@…>  [AI content] [🔒 Signed]  Tue 14:22  [Reply all] [Forward] [⋯]
│ to (RecipientBubble ×3)  +2                    WS-26 bubbles, contact card on click
│ [banners — see below, in this order]
│ body (one WKWebView, fixed frame, scrolls inside)
│ 📎 chips… [Save all to Files] [Download zip]
│ [Reply all ▾]  [smart reply] [smart reply]  "Suggested replies are using AI"
└
● Sookie   Re: lunch…                          Wed 8:01  collapsed envelope
```

- Opening a message expands it and collapses the rest; clicking a collapsed envelope expands
  it in place (it does not change the list selection) and collapses the previous one —
  **one expanded message at a time**, so one web view
  ([ADR-0085](../decisions/0085-thread-mode-expands-one-message-at-a-time.md)). Clicking the
  expanded header collapses it, except in a single-message thread. Selecting another thread
  resets expansion. Expanding an unread message marks it read through the same
  mark-as-read delay as opening it from the list.
- Collapsed envelope: avatar, sender (semibold when unread), preview text or "Encrypted
  message", the per-message subject when it differs from the thread subject ignoring
  `Re:`/`Fwd:`/`Fw:`, the "Contains AI content" chip, date with the full date as tooltip.
- The rows above and below the expanded message each scroll inside a capped band, so a
  200-message thread costs 200 rows and one web view.

**Header of the expanded message.** Sender as a `RecipientBubble` (WS-26; click opens
`ContactCardPopover`), recipients as bubbles collapsed past three, date. Chips, only when
they apply: **Contains AI content** (`hasAiGeneratedHeader`); S/MIME: **Encrypted &
verified** / **Signature verified** (`.success`) or **Signature unverified** (`.error`); no
chip for unsigned mail. Action bar: **Reply** (or **Reply all** when there is more than one
recipient, with "Reply to sender only" in the menu), **Forward**, and the **⋯** menu:

| Menu item | Behaviour |
| --- | --- |
| Reply to sender only | `openComposer(.reply(mode: .sender))` |
| Forward as attachment / Edit as new | `openComposer(.forward(asAttachment: true))` / `.editAsNew` |
| Star / Unstar, Mark important / unimportant, Mark unread | queued `setFlags` on this message |
| Translate | the translation sheet — only when the login's `llmTranslationEnabled` is not false |
| Copy direct link | `ncmail://open/<Message-ID>` on the pasteboard, label "Link copied" for 2 s; disabled with "Message ID is missing" when there is none |
| View source | a sheet "Message source", monospaced, selectable; pending until the `messageSource` row lands, offline shows the cached row or "Not downloaded yet" |
| Print message | this message only |
| Download message | save panel → `.eml` through `MessageExporter` |
| Save message to Files | WS-33 `FilesPicker(.folder)` → queued `saveToFiles(attachmentId: nil)` |
| Always show images from {domain} | queued `trustDomain`; shows images now |
| Unsubscribe | the unsubscribe confirmation, when the message offers one |

**Banners**, between header and body, each only when it applies:

1. **Phishing** — `NCNoteCard(.error)` "This email might be a phishing attempt" when
   `phishingJSON.warning` is true, listing the message of every check whose `isPhishing` is
   true; "Show suspicious links" discloses each link check's `href` vs text pairs.
2. **S/MIME unverified** — `NCNoteCard(.error)` "This message has an invalid signature. The
   sender might be impersonating someone!" when signed and `signatureIsValid == false`.
3. **PGP** — `NCNoteCard(.info)` with exactly "This message is encrypted with PGP and can't be
   read in this app." and no body, no decrypt path (ADR-0064). PGP is the envelope's
   `encrypted` flag on a message that S/MIME did not decrypt, or a plain body that is an
   inline `-----BEGIN PGP MESSAGE-----` block. Printing a PGP message prints the header only.
4. **Read receipt** — `dispositionNotificationTo` set and `$mdnsent` not:
   "The sender of this message has asked to be notified when you read this message." with
   **Notify the sender** (queued `sendMDN`; the flag lands locally at once). Afterwards
   "You sent a read confirmation to the sender of this message."
5. **Follow-up** — the message carries `$follow_up`: "You've sent this message on {date}"
   with **Disable reminder** (queued `unsetTag $follow_up`). Hidden once the `followUp`
   server result says it was answered. The primary reply button reads **Follow up** and opens
   `.reply(mode: .followUp)`; no smart replies.
6. **Unsubscribe** — a **Unsubscribe** button when there is a List-Unsubscribe URL or mailto
   and DKIM is not known bad (`dkimValid != false`; the web requires `true`, which the mirror
   never knows because DKIM verification is a separate call). The confirmation reads
   "Unsubscribing will stop all messages from the mailing list {sender}". One-click (RFC 8058)
   → queued `unsubscribe`, "Unsubscribe request sent"; a plain URL opens in the browser; a
   mailto opens the composer (`.new(mailto:)`).
7. **Remote content** — v1's bar, plus **Always show images from {domain}**.
8. **Translation** — `NCNoteCard(.info)` "Translate this message to {language}" with
   **Translate**, when translation is not known-off, the plain body is ≥ 60 characters and the
   on-device language recogniser says it is not the UI language.

**Translation sheet.** From ("Detect language" or a language) and To (defaults to the UI
language) pickers built from `Locale`; changing either clears the result. **Translate**
requests the `translation` row and shows "Translating…" until it lands. Ready: the source and
the translation side by side as plain text (an HTML body's translation is shown as text, never
rendered — it did not come through the server's purifier), "This translation is generated
using AI and may contain inaccuracies", **Copy translated text** ("Translation copied to
clipboard"). Failed: "The message could not be translated". Empty: same. Not mirrored yet:
"Please wait for the message to load".

**Reply area** under the body: the primary button (**Reply all** / **Reply** / **Follow up**),
then up to three smart replies as `.secondary` buttons with "Suggested replies are using AI"
— only when free prompt is not known-off, the mailbox is not Trash or Junk and the message is
not a follow-up. Clicking one opens `.smartReply(messageId:text:)` (WS-27 adds the AI
disclaimer and "Mark as AI generated"). Pending shows nothing; failed or empty shows nothing
(the web's fetch failure is silent too).

**Thread summary.** For a thread of three or more messages and summaries not known-off: an
`NCNoteCard(.info)` titled "Thread summary" over the subject, "Summarizing thread…" while the
row is pending, the summary when ready, nothing when empty or failed.

**Attachments.** Each chip previews in Quick Look (every type Quick Look can show, not only
images; a file not mirrored is downloaded to a temporary file by `MessageExporter` first).
Its context menu: **Download** (save panel → `MessageExporter`), **Save to Files** (picker →
queued `saveToFiles`). With more than one attachment: **Save all to Files** (one queued
`saveToFiles` per attachment) and **Download zip** (save panel → `.attachmentsZip`). Past six
chips the rest collapse behind "View {n} more attachments" / "View fewer attachments".
Embedded messages read "Embedded message".

**Printing.** `⌘P` prints the whole thread, collapsed messages included, from the mirror:
each message's escaped header then its body, separated by a rule, in one offscreen web view.
A message whose body is not mirrored prints its header and "This message has not been
downloaded yet."; a PGP message prints its header only. **Print message** in the ⋯ menu
prints only that message. A second `⌘P` while a print is up is ignored.

## Files picker and Files actions (WS-33)

Everything that touches Nextcloud Files goes through one sheet and one engine
(`FilesListingSync`, one per login). The sheet reads `filesListing` rows and never the
network (ADR-0067).

```
┌ Choose files ─────────────────────────────────────────┐
│ ‹  Home › Documents › Invoices            [All ▾] ⟳   │
│ ─────────────────────────────────────────────────────│
│ 📁 2025                                     12 Sep    │
│ ☑ 📄 receipt-0412.pdf            39 KB     29 Sep     │
│ ☐ 🖼 scan.png                    1.2 MB    30 Sep     │
│ ─────────────────────────────────────────────────────│
│ ⚠ Offline — showing the listing from 10:42.           │
│                              [Cancel]  [Choose (1)]   │
└───────────────────────────────────────────────────────┘
```

- **Opening / navigating.** Every folder shown asks the engine for its listing
  (`request(path:)`); the list renders the cached row at once. With no row yet the
  sheet shows a spinner ("Loading…"); a `failed` row with nothing cached shows "Could
  not load this folder" with Try Again. A listing younger than 60 s is not re-fetched;
  the ⟳ button forces one.
- **Breadcrumbs.** "Home" then one crumb per folder; any crumb navigates. The back
  chevron goes to the parent. Double-click (or Return) on a folder opens it.
- **Filter by type.** Popup: All, Images, Documents, Audio & video. Folders always show.
  Images = png/jpeg/gif/bmp/webp (the Insert image set).
- **Multi-select.** In `.files(multiple: true)` ⌘/⇧-click selects several files; the
  primary button reads "Choose (n)". Folders are never selectable in file mode.
- **Choose a folder mode** (`.folder`): files are listed dimmed, unselectable; the primary
  button "Choose ‹folder name›" returns the folder being shown (or the selected subfolder).
- **Offline.** Nothing is requested; the cached listing stays and a footer note reads
  "Offline — showing the listing from ‹time›." With no cache: "Offline — this folder has
  not been loaded yet."
- **Actions** (entry points belong to WS-27 composer and WS-30 message view):
  - *Attach from Files* — each chosen file becomes a `draftAttachment` row of kind
    `cloud` (`{"type":"cloud","fileName":path}`); the server copies it at send time.
    Works offline from the cache (the row is local).
  - *Insert image from Files* — filter preset to Images, single selection. Larger than
    10 MB or another type: alert "The selected image is too large to embed." / "Only PNG,
    JPEG, GIF, BMP and WebP images can be embedded." The engine downloads the bytes, the
    editor embeds a `data:` URL. Online-only.
  - *Add share link* — creates a public link (files_sharing OCS, `shareType` 3) per chosen
    file and inserts its URL at the caret. Online-only; offline shows "Share links need a
    connection."
  - *Save attachment / all attachments / message to Files* — folder mode, then one queued
    `saveToFiles` per attachment (or one with no attachment id for the message `.eml`).
    Works offline; the queue sends it later.

## Composer and outbox (WS-27)

The compose window (§6) and the Outbox list (§4.9). The composer writes the local `draft`
row and hands it to `OutboxSender` (ADR-0066, ADR-0083); it never makes a request itself.

```
┌ Reply — Quarterly numbers ──────────────────────── [📎▾] [ … ] [Send ▾] ┐
│ From  Me <me@example.com> ▾                                             │
│   To  (Alice ×) (Bob ×) type here…                         [Cc/Bcc]     │
│   Cc  (Carol ×)                                                          │
│ Subject Re: Quarterly numbers                                            │
├──────────────────────────────────────────────────────────────────────────┤
│ [ editor toolbar ]                                                       │
│ what the user writes                                                     │
│ -- signature (read-only, follows From)                                   │
│ [Hide quoted text]                               [Edit quoted text]      │
│ "Alice" alice@example.com – 4 October 2026 at 09:12                      │
│ ▌ original, sanitised server HTML, read-only (message web view)          │
├──────────────────────────────────────────────────────────────────────────┤
│ (📎 q3.pdf · 100 KB ×) (☁ report.ods ×) (✉ thread.eml ×)                 │
├──────────────────────────────────────────────────────────────────────────┤
│ Draft saved                                   Send later 5 Oct, 09:00    │
└──────────────────────────────────────────────────────────────────────────┘
```

**Windows.** `WindowGroup(id: "composer", for: ComposeRequest.self)`. One window per
request value: opening a request a window already shows brings that window forward (so a
second Reply to the same message, or a second click on the same draft, never forks the
draft). The web client's minimise is the window's minimise, its maximise the window's zoom.
Title: the subject, else "New message" / "Reply" / "Forward" / "Draft" / "Edit message"; the
kind is the subtitle once there is a subject.

**Routing** (`ComposeSeedBuilder`): `.new` (account named, else the mailbox on screen, else
the first; `mailto:` prefills To/Cc/Bcc/Subject/Body, named addresses kept, an HTML body
opens rich), `.reply` (§6.1 rules: Reply-To honoured except on mailing lists — a message
carrying an unsubscribe header is treated as one; my own sent message → its recipients;
reply-all drops my addresses and keeps Cc; self-sent → me), `.followUp` (the original
recipients), `.forward` (every attachment, inline included, as `message-attachment`
payloads; the forwarded-message header and original under the editor), `.forward(asAttachment:)`
(one `<subject>.eml` per message), `.editAsNew` ("Attachments were not copied. Please add
them manually."), `.draft` (the mirrored Drafts message; `replacesMessageId` makes the
server expunge that copy on first save), `.outbox` (see Outbox), `.smartReply` (text in the
body, "Mark as AI generated" on) and `.shared` (the Share extension's app-group inbox item,
format in `SharedInbox.swift`). Subjects get "Re:"/"Fwd:" unless they already start with a
reply/forward prefix in any of the listed languages (AW:, SV:, WG:, TR:, 回复:, …).

**Draft lifecycle.** A blank new message is not a draft until something changes. Every
change is written to the row within 0.4 s and `saveDraft` is called; the server hears 5 s
after the last edit. Status line: "Saving draft …" / "Draft saved" / "Error saving draft"
with "Save draft" (outbox edits say "message"). ⌘S saves now (WS-31's menu item). Closing
the window writes and calls `closeDraft` (offline: filed on reconnect). "… ▸ Discard &
close draft" asks once, then `discardDraft`. A restored window resumes its own row
(`@SceneStorage`), never a second draft.

**Fields.** From lists every account and alias as "Name <email>"; changing it replaces the
signature, switches to rich text when the new signature has an image, and turns S/MIME off
with a notice when the new identity has no certificate. To/Cc/Bcc are chip fields over
WS-26's `RecipientSuggestionProvider` (local first, server rows merged as they land):
Enter/blur/`,`/`;` turn valid text into chips, invalid text stays to be fixed, pasted lists
become several chips with names, duplicates are refused case-insensitively, ⌫ in an empty
field removes the last chip, more than three chips collapse to "+N" while unfocused. Cc/Bcc
rows show when toggled or prefilled. With `internal-addresses` configured, external chips
are red. Chip tooltip = address. New message focuses To, everything else the body.

**Signature and quote (§6.6).** The signature is not in the editor: it is shown read-only
under it and follows From, so changing identity replaces it exactly; plain mode prefixes
"-- ". Reopened drafts and outbox edits get none added. The quote is the server's sanitised
HTML in `<blockquote type="cite">` under a `"Name" email – <date>` header (plain: "> "
lines), drawn read-only with the message web view and remote images blocked. "Edit quoted
text" imports it into the editor (lossy, ADR-0065). Order at send time follows the account's
"Place signature above quoted text" and the `reply-mode` preference (Top/Bottom).

**Attachments (§6.7).** Paperclip menu: Upload attachment (open panel, multiple), Add
attachment from Files, Add share link from Files (WS-33's picker; the link goes in at the
caret). Drop onto the window, or paste/drop onto the editor, attaches — never inline. Chips
show name and size, a cloud for Files, an envelope for a forwarded message; × removes.
More than three get a collapsible "{count} attachments (total size)" header. Local files
are staged under Application Support and uploaded by the engine before the send.

**Warnings.** Inline: empty To with Cc/Bcc ("Messages with no 'To' recipients may be
rejected…"), replying to noreply@/no-reply@. Before send (one dialog, "Send anyway" skips
both): no subject; an attachment keyword ("attachment", "attached", and translations) in
the user's own text — before the first `>` or `--` line — with nothing attached. Send is
disabled with no recipient.

**"…" menu.** Smart picker (search sheet over the server-result engine's
`smartPickerResult` rows), Text blocks (own + shared, select → Insert; plain mode inserts
text), Insert image from Files (rich mode, WS-33's picker and size/type rules), Request a
read receipt, Mark as AI generated, Sign / Encrypt with S/MIME (enabled
only when the identity's certificate can), Save draft, Discard & close draft. Mailvelope is
excluded (ADR-0064).

**Sending (§6.8, §6.9).** Send is a split button: click sends; its menu has Send now,
Tomorrow morning 09:00, Tomorrow afternoon 14:00, Monday morning 09:00 (next week's on a
Monday) and Custom (graphical picker, default now + 1 h on a 5-minute step, nothing before
today). A chosen time shows as "Send later <date>" on the status line. Send hides the window
— it is not closed — and the main window shows "Sending message… [Undo]" for the 10 s undo
window (immediate sends only; scheduled ones go straight to the Outbox). Undo brings the
window back as "Edit message"; a failure brings it back with the reason and the banner says
"Could not send message [Edit]"; success shows "Message sent" and closes the window. Offline,
the send waits in the row and goes out on reconnect.

**Quit.** ⌘Q with composers holding unsent content asks: Save to Drafts (each is closed into
Drafts), Keep Editing, or Discard. A composer whose send is under way is not asked about.

### Outbox (§4.9)

`Outbox` in the sidebar shows `outboxMessage` rows across accounts, soonest first: avatar,
To+Cc+Bcc as a localized list, subject or "No subject", and the detail line — relative send
time, "Could not copy to "Sent" folder" (status 11), "Mail server error" (10) or "Message
could not be sent". Empty: "No messages in this folder — Pending or not sent messages will
show up here"; a failed observation: "Could not open outbox". Double-click (or "Edit
message") opens the composer; Sent-copy failures do not open. Context menu: Send now (not on
Sent-copy failures), Copy to "Sent" Folder (only on them), Delete, with "Message sent" /
"Could not send message", "Message copied…" / error, "Message deleted" / "Could not delete
message" at the bottom of the list.

Editing an outbox entry converts it to a local draft at open time (Main's WS-27 decision):
the entry is cancelled straight away, which pauses its schedule; with attachments the
cancel waits for the draft's first server save, which re-links the uploads to the new
message. Closing without sending re-schedules the draft at its original time when that is
still in the future (restoring the send time, as the web does); otherwise it is filed in
Drafts.
