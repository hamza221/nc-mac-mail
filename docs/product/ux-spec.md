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

Every selection now has its view — Contacts last, with WS-35 ([Contacts](#contacts-ws-35)); the
placeholder the shell showed until then is gone. The sync engine keeps running underneath
whichever is shown.

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
3. **Contacts**, one section per signed-in login — see [Contacts](#contacts-ws-35).
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
  fixed: "Your session has expired. Sign in again." It comes from discovery at launch or
  sign-in, or from a 401 a sync records later in the session (a mailbox sync, an envelope
  page or a body fetch); once per login until it signs in again, however many requests
  fail (`SessionExpiryTrigger`).
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
writes it to every signed-in login. Settings ▸ Appearance (WS-38) holds the same controls;
the list's toolbar View menu (Layout, Compact, Sort, Favorites on top) stays as a shortcut.

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

## Calendar in the message view (WS-34)

Parity with the web client's §5.9 (`Imip.vue`, `Itinerary.vue`, `EventModal.vue`,
`TaskModal.vue`, the attachment's "Import into calendar"). `MessageCalendarCards` sits under
the banners of the expanded message; the ⋯ menu gains **Reply with meeting** and **Create
task** right after "Edit as new message", as on the web. Everything reads the mirror — the
body row's `schedulingJSON` and attachments, the login's `calendar` rows, the account's
`imipCreate`, the login's account and alias addresses, and the `itinerary`/`eventData`
server results — and every write is a queued `calendarPut`, so answering, importing and
creating work offline and say so ("Your answer will be sent to the organizer.").

**Calendar choices.** "Save to" and "Import into" offer writable calendars that take
events, preselecting the schedule-default calendar; "Create task" offers writable calendars
that take tasks. Calendars are listed by name in mirror order.

**iMIP card** — one per iMIP object in the message, an `NCNoteCard` with the event's title,
time (in the reader's zone; an all-day event by date), location, organiser, attendee count
and description; buttons sit beside the card, not in it.

| Method / situation | Card title | Below the card |
| --- | --- | --- |
| REQUEST, the user is an attendee, no answer, ahead | You have been invited to an event | **Accept** · Decline · Tentatively accept · More options |
| REQUEST, answered here (queued or sent) or already answered in the attached copy | You accepted / tentatively accepted / declined this invitation (else "You already reacted to this invitation") | — |
| REQUEST, dates behind us (a series: its `UNTIL`) | You have been invited to an event | "This message has an attached invitation but the invitation dates are in the past" |
| REQUEST, no ORGANIZER/ATTENDEE matches an account or alias address | Calendar event | "…does not contain a participant that matches any configured mail account address" |
| REPLY from one attendee | {name} accepted / tentatively accepted / declined / reacted to your invitation | — |
| REPLY with zero or several attendees | This event was updated | — |
| CANCEL | This event was cancelled (error card) | — |

**More options** opens "Save to" (only when more than one calendar can take it; hidden when
the account's "create tentative appointments" `imipCreate` is on — the server puts the event
in the default calendar itself, so the answer has to update that copy, and a caption says so)
and a **Comment** field. The answer is the attached object without METHOD, with PARTSTAT on
the user's own ATTENDEE line in every VEVENT, RSVP cleared, and the comment as
`X-RESPONSE-COMMENT` and COMMENT. Nextcloud's scheduling sends the organiser the REPLY;
when the calendar already holds the UID the write lands on that copy (ADR-0093). A reopened
card shows an answer still waiting in the queue; once sent, it shows the buttons again,
because calendar objects are not mirrored
([ADR-0101](../decisions/0101-an-answered-invitation-shows-its-buttons-again-once-sent.md)).

**Itinerary cards** — the `itinerary` server result for the message (kept 30 days), one card
per reservation, de-duplicated by UID: flights ("Flight LH123 from TXL to MUC", times,
reservation number), trains (by times, or by travel day as an all-day event), events (start,
two hours when there is no end, place and GEO). Other types read "Itinerary for {type} is not
supported yet". **Import into calendar** is a menu of calendars; afterwards it reads
"Imported into {calendar}". The UID is the web's `md5(messageId + …)`, so importing again
— here or from the web — updates the same event.

**`.ics` attachments** — one row per calendar attachment (`isCalendarEvent`, a calendar MIME
type, or `.ics`), not shown when the message carries an iMIP object: name and **Import into
calendar**. The file is split into one object per UID with its VTIMEZONEs, as the web does;
the bytes come from the mirror or the one-shot exporter.

**Reply with meeting** (sheet): Title, All day, From, To (not before From), Calendar,
Attendees (the sender and the To recipients minus the user's own addresses; remove each, add
by address), Description (the body's opening, 255 characters). It opens on the next full hour
for an hour — the web opens on "now". When the instance has an LLM (`llmSummariesAvailable`
not false), "Generating event details…" shows while the `eventData` result is asked for, and
its title and description (plus "This description was generated by AI.") replace the
prefilled ones unless the reader has typed. With attendees, ORGANIZER is the account the
message arrived in. **Create** queues the event and closes; "Event created".

**Create task** (sheet): Title, Task list, All day (on), optional Start and Due, Note. A
VTODO with CREATED, DESCRIPTION, DTSTART/DUE and `X-OC-HIDESUBTASKS:0`. With no task list
the sheet says "No task lists". "Task created".

Failures show one sentence under the cards ("That calendar is read-only.", "The file is not
a calendar file this app can read.", "Could not save to the calendar.").

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

## Account settings (WS-39)

§8 of the web client's checklist, per account. Hosted by the Settings window's **Accounts**
tab (WS-38 owns the tab, its sidebar and the account header; layout under "App settings
(WS-38)"): the tab's sidebar lists each account's **pages**, and selecting one shows
`AccountSettingsView(accountId:group:)`, which renders that one page as a grouped `Form` that
scrolls on its own. The sidebar's *Account settings…* and the "cannot connect" row open the
Settings window on that account (`SettingsTab.preferredAccountID`). Opening Settings re-reads
server state (`.settingsOpened`), so every section shows the mirror first and fresher rows a
moment later.

**Pages.** The sixteen §8 sections are grouped into nine pages (`AccountSettingsGroup`), in
this order; a page lists only the sections visible for the account (table below), and a page
with none is not listed. Each section is on exactly one page.

| Page | Sections |
| --- | --- |
| General | Aliases, Alias certificates, Writing mode, Classification, Calendar |
| Signature | Signature |
| Folders | Default folders, Automatic trash deletion, Folder search |
| Autoresponder | Autoresponder |
| Filters | Filters |
| Quick actions | Quick actions |
| Mail server | Mail server |
| Sieve | Sieve server, Sieve script |
| Delegation | Delegation |

Sections with sheets or dialogs (Signature, Autoresponder, Filters, Quick actions, Mail
server, Delegation) each have a page to themselves. Links between sections move the page:
Aliases' *Edit* opens Mail server, the Sieve hint card's *Go to Sieve settings* opens Sieve.
Switching to an account that lacks the page shown (a delegated account has no Mail server
or Delegation) shows General.

Every section reads the store. Writes go one of two ways (ADR-0068):

- **Queued** (offline-safe, applied locally at once): writing mode, signatures, the six
  default folders, trash retention, body search, classification, calendar, aliases, quick
  actions. No toast, as the web; a refused replay surfaces later in the status footer.
- **Commands** (online only, spinner on the button, inline error under it — "Oh Snap!
  {message}" with the server's text): alias certificate, autoresponder, mail server,
  connection test, Sieve server, Sieve script, filters, delegation.

**Section visibility.**

| Section | Shown |
| --- | --- |
| Aliases, Alias certificates, Writing mode, Signature, Default folders, Automatic trash deletion, Folder search, Autoresponder, Classification, Quick actions | always |
| Calendar | when the server's account payload carries `imipCreate` (Mail on NC ≥ 33) |
| Filters | always: the list when Sieve is on, otherwise the hint card |
| Mail server | not delegated; provisioned → locked |
| Sieve server | provisioned → locked |
| Sieve script | Sieve on |
| Delegation | not delegated, not provisioned |

A **locked** section (provisioned account, `provisioningId != nil`) keeps its title and shows
only: "This account is managed by your administrator. Its server settings come from the
provisioning configuration and cannot be changed here." Nothing else is editable there.

**Aliases (§8.1).** First row is the primary identity, "**Name** <email>", not deletable;
for an unprovisioned account its *Edit* button opens the Mail server page. Each alias row: name and
address, *Rename alias* (inline name + email fields, *Update alias*; the email field is
disabled for a provisioned alias), *Delete alias* (hidden for provisioned aliases). *Add
alias* (not on a provisioned account): Name (prefilled with the account name) + Email, both
required, *Create alias* / *Cancel*. All queued: a created alias shows at once under a
placeholder id (ADR-0081) and may be renamed or deleted before it reaches the server.

**Alias certificates (§8.2).** *Select an alias* (primary + aliases) → certificate pop-up
"{commonName} - Valid until {date}" plus "No certificate", filtered to certificates with a
private key, the identity's email, still valid tomorrow, and able to sign and encrypt.
*Update Certificate* disabled until a choice differs from the current link; outcome inline:
"Certificate updated" / "Could not update certificate". An unverified chain shows the
warning "The selected certificate is not trusted by the server. Recipients might not be able
to verify your signature."

**Writing mode (§8.3).** Radio Plain text / Rich text, saves on change (`editorMode`
`plaintext`/`richtext`); the radio follows the store, so a refused patch rolls back with it.

**Signature (§8.3).** Switch "Place signature above quoted text" (queued patch). Identity
pop-up when the account has ≥ 1 alias. The editor is the composer's (`ComposerEditor`):
plain when the writing mode is plain and the loaded signature has no image, otherwise rich.
Warnings (note cards, live with the content): over 2 MB — "This signature is larger than
2 MB, usually because an image is embedded in it. It is added to every message you send and
may slow down the editor."; images on a plain account — "This signature contains images. New
messages will use rich text, even though your writing mode is set to plain text." *Save
signature* (queued, no toast) and *Delete* (only when one exists).

**Default folders (§8.3).** Six `InlineMailboxPicker`s — Drafts, Sent, Deleted (trash),
Archived, Snoozed, Junk — each saves on change as one `patchAccount` field.

**Automatic trash deletion (§8.3).** "Days after which messages in Trash will automatically
be deleted:" number ≥ 0, saved 1 s after the last keystroke; 0 or empty disables it.

**Folder search, Classification, Calendar (§8.3, §8).** One switch each: "Enable mail body
search", "Enable mark as important classification", "Automatically create tentative
appointments in calendar"; each saves on change.

**Autoresponder (§8.4).** Without Sieve: the hint card (below). With Sieve: "The
autoresponder replies at most once every 4 days per sender." Radios Off / On / "Follow
system settings" (only when the login's `enableSystemOutOfOffice` is not false), the last
with *Edit absence settings* opening `/settings/user/availability` in the browser. Form:
First day; "Last day (optional)" checkbox (on → first day + 6, and moving the first day keeps
the gap); Subject with the hint "${subject} will be replaced with the subject of the message
you are responding to"; Message. Fields are disabled unless On. *Save autoresponder* is
enabled for Off and Follow system, and for On once first day, subject and message are set
and the last day is not before the first. Values are re-read from the store after save.

**Sieve server (§8.5).** Intro: "Sieve is a powerful language for writing filters for your
mailbox. You can manage the sieve scripts in Mail if your email service supports it. Sieve
is also required to use Autoresponder and Filters." Switch "Enable sieve filter" reveals Host
(defaults to the IMAP host), Security None / SSL/TLS / STARTTLS (default STARTTLS), Port
4190, Credentials "IMAP credentials" / "Custom" (User + Password). *Save sieve settings*.
After enabling, Autoresponder, Filters and Sieve script switch from the hint to their form.

**Sieve hint.** "Your mail server does not support Sieve or Sieve is not enabled. Autoresponder
and filters require it." with *Go to Sieve settings* selecting Sieve server.

**Sieve script (§8.5).** A monospaced 20-line editor (`TextEditor`), disabled until the
script row has arrived; *Save sieve script*. A 422 shows, under the editor, "Oh Snap! The
syntax seems to be incorrect: {server message}" — the parser's own line and column.

**Filters (§8.6).** "Hang tight while the filters load" until the Sieve row has its filters.
Rows: name and "Filter is active" / "Filter is not active"; click opens the editor sheet;
row *Delete filter* → "Delete mail filter {name}?" / "Are you sure to delete the mail
filter?" → inline "Filter deleted" / "Could not delete filter". *New filter* opens the editor
with: name "New filter", enabled, all conditions, one Subject + "is exactly" condition, one
Move into folder action, priority max + 10. The sheet does not close on an outside click;
its title is the filter's name.
Editor: Name; operator pop-up "If all the conditions are met" / "If any of the conditions
are met"; a help popover ("contains" matches part of the text, "matches" takes `*` and `?`);
condition rows Subject / Sender / Recipient × is exactly / contains / matches × values
(comma-separated tokens); *Add condition*. Actions: Mark message as (Answered, Deleted,
Draft, Flagged, Seen), Add flag (text), Move into folder (`InlineMailboxPicker`; the server
wants the folder's path), Stop ("Stop ends all processing", always kept last); *Add action*
inserts before a Stop. Priority (required) and "Enable filter". *Save filter* → the whole
list goes up as one `saveFilters` command; "Filter saved" / "Could not save filter"; the
Sieve script refreshes with it. The web's "Redirect to" is not offered: the Mail 5.12 server
this was built against does not compile it into Sieve.

**Quick actions (§8.7).** Empty: "No quick actions yet." Rows with *Edit* / *Delete*
("Quick action deleted" / "Failed to delete quick action"). *Add quick action* / *Edit*
opens a sheet: Name; "Do the following actions" — the steps in order; *Add another action*
menu: Mark as spam, Tag, Move thread, Delete thread, Mark as read, Mark as unread, Mark as
important, Mark as favorite. **Terminal steps** (spam, move, delete) end the run, so: at most
one, always last; once present the menu offers only non-terminal steps and inserts them
before it; it cannot be moved. Reorder with ↑/↓ (never past the terminal step). Remove (✕)
deletes a saved step at once (queued). Tag step: tags except Important and the hidden system
tags; Move step: folders with the `i` right. *Save* disabled until a name, ≥ 1 step, and
every tag/folder chosen. All queued, including a new action's steps against its placeholder
id.

**Delegation (§8.8).** "Allow users to send, receive, and delete mail on your behalf" and
the delegate list. *Add delegate*: a search field (300 ms debounce, user sharees, excluding
yourself and existing delegates); *Delegate access* disabled until a user is picked; outcome
"Delegated access to {name}" / "Could not delegate access". Row ✕ *Revoke access* →
"Revoke access?" / "{user} will no longer be able to act on your behalf" → "Revoked access
for {name}" / "Could not revoke delegation".

**Mail server (§8).** IMAP and SMTP: host, port, security (None / SSL/TLS / STARTTLS), user,
password (blank keeps the stored one; no password fields on an OAuth account); prefilled from
the account. *Save* runs `updateMailServer` → "Mail server saved" or "Oh Snap! {message}";
the command re-reads the account after the PUT, whose answer is partial (server-findings 33).
*Test connection* runs `testConnection` and shows "Connection successful" / "Could not
connect" from its `serverResult` row.

## Mail account setup (WS-40)

Parity with the web client's `AccountForm.vue` (checklist §1.1–§1.5). A sheet,
`AccountSetupSheet`, presented by `AddMailAccountButton(sessionId:)` — the "Add mail
account" control WS-38 places in Settings, one per login. Account creation, discovery and
the connection test are online-only `SettingsCommands` (ADR-0068); the sheet awaits only
outcomes and reads discovered values back from `serverResult` rows.

**Hidden** when the login's `allowNewAccounts` is `false`: the button disappears (and
reappears if the admin re-allows); a sheet already open shows only "To add a mail account,
please contact your administrator." nil — not yet discovered — counts as allowed; the
server's own refusal then arrives as "There was an error while setting up your account".

**Mode.** Segmented "Auto" / "Manual", Auto by default, disabled while running.

**Auto mode.** Name (focused), Mail address, Password, "Enable mark as important
classification" (default from `importanceClassificationDefault`, else on). An address that
fails the web client's regex shows "Please enter an email of the format name@example.com"
live. Connect is disabled until the address is valid and a password is entered — the
password becomes optional only when *both* Google and Microsoft OAuth URLs are known (the
web client's rule).

**Button label sequence** while running, on the Connect button itself:
"Looking up configuration" (ISPDB for the address's domain; then MX; then ISPDB for the
first MX host's last two labels — the known `.co.uk` limitation is kept) → "Checking mail
host connectivity" (first MX host, ports 993/143/465/587 in parallel; IMAP needs 993,
SMTP 465 or 587) → "Testing authentication" (`createAccount`) → ["Awaiting user consent"
for OAuth] → "Loading account" (until the new account's mailboxes are mirrored, at most
30 s). Every field is disabled and a spinner shows while it runs. Whatever discovery found
is written into the Manual fields, so switching to Manual after a failure shows it.

**Manual mode.** IMAP group (Host, Security None / SSL/TLS / STARTTLS, Port, User,
Password) and the same for SMTP. Defaults IMAP 993 SSL/TLS, SMTP 587 STARTTLS. Picking a
security sets the port: IMAP none/STARTTLS → 143, SSL/TLS → 993; SMTP none/STARTTLS → 587,
SSL/TLS → 465. Entering Manual fills empty users with the address and empty passwords with
the Auto password. Editing IMAP host, user or password mirrors into SMTP until any SMTP
field is edited; from then on the two are independent. Save is disabled until every field
is filled; hosts are trimmed when sent.

**Google / Microsoft.** `imap.gmail.com`/`smtp.gmail.com` and `outlook.office365.com` are
detected. Without the provider's OAuth URL on the login row a hint shows (Google: app
password; Microsoft: ask the admin) — also after Auto discovery found such a host. With it,
password fields are hidden and the button reads "Sign in with Google" / "Sign in with
Microsoft". Flow: create (authMethod `xoauth2`) → "Account created. Please follow the pop-up
instructions to link your Google account" → `startOAuth` → the URL (`_state_`, `_email_`
filled) opens in an `ASWebAuthenticationSession` window; completion is observed by polling
the connection test every 2 s for up to 10 min (ADR-0094). If the session cannot start, the
default browser opens instead and the same poll runs, with a Cancel button. Closing the
window, Cancel, or the 10 min limit → "Authorization pop-up closed" and the temporary
account is deleted (`deleteAccount`).

**Errors (§1.5)**, one line under the form, cleared by editing any field:
"IMAP/SMTP username or password is wrong", "IMAP/SMTP server is not reachable",
"IMAP/SMTP server denied authentication", "IMAP/SMTP authentication error", "IMAP/SMTP
connection failed", "Configuration discovery failed. Please use the manual settings",
"Configuration discovery temporarily not available. Please try again later." (any 429),
"Authorization pop-up closed", "Password required", "There was an error while setting up
your account" (anything else).

**Done.** The sheet closes and the sidebar selects the new account's inbox.


## App settings (WS-38)

Web client §7 (`AppSettingsMenu.vue`) mapped onto the `Settings` scene. It supersedes the
three-tab layout in [Settings](#settings) above; Storage keeps its panel unchanged. One
`TabView`, `Form` + `.formStyle(.grouped)` in every tab. Tabs, in order: **General,
Accounts, Appearance, Messages, Privacy, Security, Assistance, Context Chat, Shortcuts,
Storage, About**.

**Which login.** Preferences are per Nextcloud login on the server but one window has one
setting, so a switch is read from the first login (lowest id) and written through the
queue's `setPreference` to **every** login, exactly as WS-29's list preferences do
(ADR-0088, reusing `MessageListPreferenceStore.write`). Lists that belong to one server —
trusted senders, internal addresses, text blocks, S/MIME certificates — show a
"Nextcloud account" picker above them when more than one login is signed in, and act on the
picked login ([ADR-0091](../decisions/0091-app-settings-scope.md)).

**Saving.** Switches and pickers apply immediately: the queue applies the row in the same
transaction, so the control reflects the mirrored value at once and offline changes drain
later. A failure to queue shows the web's message inline under the control ("Could not
update preference", "Could not remove trusted sender {sender}", "Could not remove internal
address {sender}", "Could not add internal address {address}"). S/MIME import and delete are
ADR-0068 commands: a spinner while running, the server's verdict after.

**General** — "Set as default mail app" button. It calls
`NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
toOpenURLsWithScheme: "mailto")`; the label reads "Default mail app" (disabled) whenever
`NSWorkspace.shared.urlForApplication(toOpen: mailto:)` resolves to this bundle, re-checked
when the tab appears, after the call completes, and when the app becomes active (the user
may change it in Mail.app's settings meanwhile). Then "Account settings": one row per mail
account (`{email}`, or `{email} (delegated)` for a delegated account); clicking a row opens
the Accounts tab on that account (`SettingsTab.preferredAccountID`). Then WS-40's
`AddMailAccountButton` ("Add mail account", presenting `AccountSetupSheet`) once per login,
captioned "{login} on {host}" when several logins are signed in; it hides itself while the
login's server disallows new accounts (`login.allowNewAccounts == false`). A declined
Launch Services prompt shows "Could not set this app as the default mail app.".

**Accounts** — a sidebar (220 pt, `List(selection:)`, so arrow keys move through it): one
section per mirrored account, headed by its address (`NCNavigationCaption`), listing that
account's settings pages (`NCNavigationItem`, see "Account settings (WS-39)"); under the
list, the same "Add mail account" buttons as General, captioned per login when several are
signed in. The selection is the account (`SettingsTab.preferredAccountID`, defaulting to the
first account) and the page (General by default, kept across accounts that have it). On the
right, a header for the selected account — avatar, name, address, "{status} · Last synced
{time}", then *Open Web Client* and *Sign Out* — above the selected page. *Sign Out* runs the
two-question flow (pending actions, then keep or remove local copies).

**Window size.** One size for every tab, set on the tab view: at least 780 × 520 pt, ideally
820 × 580. No tab sets its own minimum, so the window does not jump between tabs; each tab's
`Form` scrolls inside it.

**Appearance** — the web's §2.4 controls over the same preferences WS-29 reads
(`MessageListPreferenceStore`): "Show all messages in thread" (`layout-message-view`,
`threaded`/`singleton`, default off), "Sort favorites up", Layout (Vertical split /
Horizontal split / List), "Use compact mode", Sorting (Newest first / Oldest first). The
local Threaded/Flat picker that lived in General moves here as "Group messages" ("Kept on
this Mac only."); it groups list rows and is not the server preference.

**Messages** — "Avatars from Gravatar and favicons" (`external-avatars`, default on),
"Search the body of messages in priority Inbox" (`search-priority-body`, default off),
"Mark messages as read" Immediately / After 3 seconds / After 30 seconds / Manually
(`auto-mark-as-read` = `0`/`3000`/`30000`/`-1`, default 3 s on the server; the reader's
local delay is written in the same action so opening a message follows it at once),
"Reply position" Top / Bottom (`reply-mode`), then **Text blocks**:

- List of own blocks with title and a one-line plain-text preview, a share glyph on blocks
  that have shares, Edit (pencil, "Edit {title}") and Delete (trash, no confirmation). Empty:
  "No text blocks available". Below, "Shared with me" with blocks others shared, opening a
  read-only view.
- "New text block" sheet: title field + `RichTextEditor` (with the composer's toolbar);
  Ok disabled until both are non-empty; Cancel discards. Queued as `createTextBlock`.
- Edit sheet: the same fields plus **Shares** — a search field over the server's sharees
  (users then groups, excluding the signed-in user and existing sharees), the share list
  (users then groups) with a remove button each. Share/unshare are queued
  (`shareTextBlock`/`unshareTextBlock`) and show "Text block shared with {sharee}" / "Share
  deleted for {name}"; Ok queues `updateTextBlock`.

**Privacy** — "Data collection" (`collect-data`, default on, "Allow the app to collect and
process data locally to adapt to your preferences"). "Always show images from": the
`trustedSender` rows, domain glyph for domains, person glyph for addresses, Remove on each
(queued `trustDomain`/`trustSender` with `trusted: false`). Empty: "No senders are trusted at
the moment."

**Security** — "Highlight external addresses" (`internal-addresses`, default off). The
internal-address list, domains first, Remove on each; "Add internal address" sheet with one
field: `@example.com` → domain `example.com`, `a@b` → address; Cancel / Add. Queued
`addInternalAddress`/`removeInternalAddress`. Then **S/MIME** → "Manage certificates…" sheet:

- Table Certificate name / E-mail address / Valid until, delete button per row (no
  confirmation). Empty: "No certificate imported yet". Opening the sheet asks the server
  state mirror for a fresh pass (`settingsOpened`).
- "Import certificate": PKCS #12 (default) or PEM. PKCS #12: one `.p12`/`.pfx` file and a
  password field; PEM: a certificate file (`.crt`/`.pem`) and an optional private key
  (`.key`/`.pem`) with the hint that the key must not be passphrase protected. Import is
  disabled until a file is chosen; Back returns to the table.
- PKCS #12 is converted **on this Mac** (`SecPKCS12Import` in memory only, then
  `SecKeyCopyExternalRepresentation` / `SecCertificateCopyData` to PEM) and only the PEM
  reaches `SettingsCommands.importSMIME`. The password is used for the import call and
  dropped; it is never logged, stored or sent.
- Errors, verbatim from the web: "Failed to import the certificate. Please check the
  password." (wrong password / not PKCS #12), "The provided PKCS #12 certificate must contain
  at least one certificate and exactly one private key.", "Failed to import the certificate.
  Please make sure that the private key matches the certificate and is not protected by a
  passphrase." (any failed upload that carried a key — the web's rule; the server answers a
  mismatched key with a 500 like any other failure), "Failed to import the certificate"
  (otherwise). Success: "Certificate imported successfully". Mailvelope is excluded
  (ADR-0064).

**Assistance** — "Remind about messages that require a reply but received none"
(`follow-up-reminders`, default on). **Context Chat** — "Make mails available to Context
Chat" (`index-context-chat`, default on). Each control is enabled when at least one login's
server reports the feature (`llmFollowupAvailable`, `contextChatAvailable`); otherwise the
tab explains that the server does not offer it (ADR-0091: a tab that vanishes reads as a
bug in a native settings window).

**Shortcuts** — the Help ▸ Keyboard Shortcuts content (`KeyboardShortcutsView`), embedded.

**About** — app version, then "Acknowledgements": this build includes no CKEditor (the
native editor is `RichTextEditor`), so the web's GPLv2 CKEditor line is replaced by the
NextcloudUI and GRDB acknowledgements.

## Contacts (WS-35)

Browse, view and edit every contact of every signed-in login, offline included. Everything
here reads the mirror ([ADR-0069](../decisions/0069-contacts-same-database.md)); every write
is a queued operation that lands in the mirror at once and reaches the server when the
drainer runs. Address books, import/export, merge and batch actions are WS-36's; Teams are
WS-37's.

**Sidebar** ([ADR-0070](../decisions/0070-contacts-sidebar-section.md)), one section per login,
captioned "Contacts" (or "Contacts · *login*" when several logins are signed in), between the
accounts and the Outbox. Rows, each with its count: **All contacts**, **Favorites**, each
enabled address book except Recently contacted, the **contact groups** (every `CATEGORIES`
value of the login's cards, natural case-insensitive order), and **Recently contacted** while
the server's `contactsinteraction` book exists and is enabled. The Teams rows follow the
groups ([Teams, shared items and the organisation chart](#teams-shared-items-and-the-organisation-chart-ws-37)). Web Contacts' "Not grouped" entry has no
`ContactsScope` case and is not offered
([ADR-0102](../decisions/0102-no-not-grouped-contacts-entry.md)).

**List** (content column). People only — `KIND:group` cards are not listed, as in web
Contacts. Favourites first, then by the **sort setting**: web Contacts' `orderKey` (First name,
Last name, Phonetic first name, Phonetic last name, Display name — the default —, Last
modified), kept per Mac like the browser keeps it, in the toolbar's sort menu and under the
same key WS-36's Contacts settings row writes. The row's name follows the order as the web's
`Contact.displayName` does ("Kim, Lane" by last name), with the first address (else the
organisation) under it, the address's avatar, and a star on favourites. Ties keep a stable
order; empty sort values go last; Last modified is newest first. **Search** filters the
scope through `contactSearch` (every word a prefix of a name, nickname, organisation or
address). **Multi-select** with ⌘/⇧-click; two or more selected show "*N* contacts selected"
in the detail column, where WS-36's batch actions go. Context menu: New message, Add to /
Remove from favorites, Delete. ⌫ deletes a single selected contact after a confirmation.
**New contact** (toolbar) opens an empty editor in the detail column; nothing is written until
Save.

**Detail** (detail column). An `NCProfileCard` — the card's own PHOTO, else the address's
avatar; name; title · organisation, nicknames, address book — with **New message** (to the
preferred, else first, address, from the login's first account), the **favourite star**,
**Edit**, and a ⋯ menu: Upload picture…, Show full size, Download picture…, Remove picture,
Get picture from › *network*, Delete contact. Then every typed property as a labelled row
(Name, Nickname, Organization, Title, Email, Phone, Address, Website, Instant messaging,
Social network, Related, Birthday, Anniversary), with mailto/tel/http links; **Groups** as
chips; **Notes**; **Other properties (*n*)** — every line this app does not model, shown as
written, never edited; and **Recent mail** with the preferred address (WS-26's
`RecentMailList`, ten messages, click opens the mailbox).

**Edit mode** replaces the card in place: Name (display name — its placeholder is what will
be saved if left empty —, prefix, first, additional, last, suffix, nickname), Work
(organisation, department, title), one section per multi-valued property with a type menu
per row (web Contacts' type choices, plus whatever type the card already had), Add/Remove
rows, Dates (`YYYY-MM-DD`, kept as typed), Groups (chips with remove, "New group", "Existing
group" menu), Notes, and the read-only other properties. Cancel discards; Save queues one
`contactPut` (If-Match on the base ETag, the 412 re-apply of ADR-0069). Save rewrites only
what changed: an untouched property keeps its original line byte for byte, a changed row
keeps its group (`item1.`) and every parameter but `TYPE`, and `REV` is stamped like web
Contacts does on every save. A new contact goes to `<book>/<UID>.vcf` in the shown book when
writable, else the login's own "Contacts"; from a group list it starts in that group, from
Favorites it is starred too.

**Photo.** Upload opens a picture, then a square crop sheet (drag to move, Zoom slider —
web Contacts' cropper is `aspectRatio: 1, dragMode: move`); the crop is scaled to at most
512 px like the web's, and saved as JPEG (`PHOTO;ENCODING=b;TYPE=JPEG` in 3.0, a `data:` URI in
4.0). Remove deletes PHOTO. Full size shows it in a sheet with Download…; Download writes the
bytes as stored. **Get picture from** lists web Contacts' `supportedSocial`: of the server's
supported networks (instagram, mastodon, tumblr, diaspora, xing, telegram, gravatar), those
the card has an `X-SOCIALPROFILE`/`IMPP` of that type for, plus Gravatar when it has an
address. It queues a `contactSocialAvatar`; the server fetches the picture and rewrites PHOTO,
and the pass the send wakes brings it in. The picture actions live on the card, not in edit
mode, and each saves at once.

**Favourites** are web Contacts' star — the `{http://nextcloud.com/ns}favorite` DAV property
on the card, not a vCard property
([ADR-0092](../decisions/0092-contact-favourites-are-a-dav-dead-property-refreshed-each-pass.md)).
The toggle flips the row at once and queues a `contactFavorite` (PROPPATCH); a star set in the
browser arrives with the next contacts pass.

**Read-only address books** (a share without write access): Edit, the star, Delete and the
picture actions other than Full size/Download are disabled, and the card says why — "*Book* is
shared read-only by *owner*, so its contacts cannot be edited." New contact never offers a
read-only book; with none writable it is disabled with "There is no address book you can add
contacts to."

**Offline.** All of the above works without a network: the list and card read the mirror, and
writes wait in the queue (a write refused because the login is signed out says "Sign in to
this account to edit contacts.").

## Address books, import, merge (WS-36)

Everything here is a queued write ([ADR-0096](../decisions/0096-address-book-import-and-merge-are-queued-card-writes.md)).
It shows up in the mirror at once and reaches the server when the drainer runs, so it all works
offline. Refusals are shown as a line under the sheet's controls ("Sign in to this account to
edit contacts.", "This address book is read-only.", "Only the owner of a shared address book
can change it.").

**Entry point.** The Contacts section's caption in the sidebar has a ⋯ menu with **Manage
address books…**, **Import vCard…** (disabled when no book is writable) and **Contacts
settings…**. Each one opens a sheet.

**Manage address books** lists every book of the login, including disabled ones, in the
server's order. Each row has:
- a switch for on/off: web Contacts' `oc:enabled`, so turning a book off hides it in the
  browser too;
- the name;
- a caption: "Shared by *owner*", "Read-only", "*n* contacts", or "Hidden".

The ⋯ menu on each row:
- **Rename** edits the name in place; Return saves it and Escape cancels.
- **Share…** opens the share sheet.
- **Export…** saves `Name.vcf` with every card in the book, read from the mirror, so it works
  offline and for hidden books.
- **Copy CardDAV URL** puts the collection URL on the clipboard.
- **Delete…** asks first: "Every contact in it is deleted from the server too, as soon as this
  Mac is online."

Rename, Share and Delete are available only on the login's own books, and never on Recently
contacted. A field and **Create** at the bottom make a new book at
`<home>/<slug of the name>/`; a slug that is already taken gets a number (`family-2`).

**Share** has a user/group search (the sharee search used by text blocks, debounced) and a
**Read-only** switch, on by default. Clicking a result shares the book with that person or
group and lists them under "Shared with". Sharing again with someone changes their access to
whatever Read-only says now. Existing shares are not listed and cannot be removed; see the
ADR.

**Import vCard** opens a file picker for `.vcf` (3.0 or 4.0, any number of cards), plus an
**Import into** picker of writable books (the default is the same book New contact uses). Once
a file is chosen, the sheet says "*n* contacts in the file", or, when some UIDs are already in
the book, "*n* new, *m* already in this address book (they are updated)". **Import** queues one
write per card and shows a progress bar ("Queued *k* of *n*"). When it finishes: "*n* contacts
imported. They reach the server as soon as this Mac is online." Cancel stops between cards;
cards already queued stay queued.

**Batch actions.** When two or more contacts are selected, the detail column shows "*N*
contacts selected" with:
- **Merge…**, only for exactly two people, both in writable books;
- **Export…**, which saves the selection as one `.vcf`;
- **Delete**, which uses the list's own confirmation ("Delete *N* contacts?") and is disabled
  if any selected contact is read-only.

**Merge** sheet:
- **Keep**: a segmented choice of which contact survives. The default is the fuller card. The
  other contact is deleted.
- **Choose one**: a radio group for each single-value property the cards disagree on
  (Display name, Name, Nickname, Organization, Title, Role, Birthday, Anniversary, Gender,
  Notes, Picture). The kept card's value is the default; an empty field on the kept card
  defaults to the other card's value.
- **Keep**: a checkbox for each email, phone, address, website, IM, social profile and related
  line. Every line is ticked by default; a line that appears on both cards (case or punctuation
  aside) is listed once.
- **Groups**: "Combine groups", on by default, with the resulting list.

**Merge** queues one write over the kept card and one delete of the other, then selects the
kept card. Any property the sheet does not list stays as the kept card has it.

**Contacts settings**:
- **Sort contacts by**: the same `contacts.orderKey` as the list's toolbar menu.
- **Update avatars from social media**: when on, opening a contact in a writable book asks the
  server to fetch its picture from the first social network the card lists, at most once a day
  per contact.

Both settings are per Mac.

## Teams, shared items and the organisation chart (WS-37)

Three Contacts features that depend on the server: Teams (the Circles app), the items shared
with a Nextcloud user, and the organisation chart
([ADR-0097](../decisions/0097-teams-are-mirrored-rows-and-online-commands.md)). Lists read
the mirror; team edits are online-only and wait for the server's answer.

**The gate.** Teams appear only when the server says it runs Circles (its capabilities list
`circles`). On a server without it there is no Teams row, no "New team", no empty state and no
disabled control — nothing. Until the first answer arrives nothing shows either; a team list
from an earlier launch shows offline.

**Sidebar**, after the contact groups in each login's Contacts section:
- one row per team the login belongs to, with the team icon and its member count;
- **New team…**, which opens a sheet: the web's one-line explanation, a name field, **Create
  team**. The sheet closes when the server has created the team and the new row is in the
  sidebar; a refusal shows the server's message under the field.

**Team** (content column, in place of the contact list when a team row is selected):
- the description, then "*N* members · Owned by *name*" (or "You own this team");
- **Add members** (moderators and up, or anyone when the team lets members invite), **Team
  settings** (owner and admins), and a ⋯ menu: Open in browser, Leave team (anyone but the
  owner, after a confirmation), Delete team (owner only, after a confirmation);
- **Members**, owner first, then by level, then by name: avatar, name, "*kind* · *level*"
  (User/Group/Email/Contact/Team; Member/Moderator/Admin/Owner, or "Requesting to join" /
  "Invited"). Each row's ⋯ (and context) menu offers what web Contacts offers for that member:
  Accept / Reject for a join request; "Promote to …" / "Demote to …" for the levels below
  the login's own (admins may also make admins; the owner may "Promote as sole owner"); Leave
  team on the login's own row; Remove member otherwise.

**Add members** sheet: a segmented choice of **Users and groups** (a search field over the
server's sharee search; existing members are disabled), **Email address** (a field and Add)
or **Team** (the login's other teams). Each pick is added at once and listed under "Added:";
**Done** closes.

**Team settings** sheet: Name, Description and web Contacts' options, grouped as it groups
them — Invites (Anyone can request membership; Members need to accept invitation;
Memberships must be confirmed/accepted by a Moderator; Members can also invite), Membership
(Prevent teams from being a member of another team), Federation (Allow federated members),
Privacy (Visible to everyone). **Save** sends only what changed.

**Shared items** (contact card, after Recent mail), for a card in the system address book
other than the login's own: the files shared between the login and that user, both
directions, newest first — name, "Shared with you · *date*" or "You shared · *date*". A click
opens the file in the web Files app. "No shared items with this contact" when there are none.
Web Contacts also lists Talk, Calendar and Deck items there, through the `related_resources`
app; that app is not part of a default server, so this list is Files only.

**Organization** (contact card, after Recent mail), for a card that has a manager or reports:
"Reports to" (the chain of managers, nearest first) and "Direct reports", each name a link
that selects that contact, and **Show organization chart**, a sheet with the card's whole
chart as indented levels (the card in bold; a click selects a person). The manager is web
Contacts' `X-MANAGERSNAME;UID=` (also what the server writes from a user profile's Manager
field), looked up in the card's own address book. A manager that is not in the book is said
so ("Manager *name* is not in this address book") and the card heads its own chart; a
reporting loop is cut at its alphabetically first member, which says so.

## Notifications and the Dock badge (WS-41)

Notification Center banners for new mail and for the Mail app's Nextcloud notifications, and
the Dock icon's unread badge. Everything reads the mirror
([ADR-0098](../decisions/0098-new-mail-notifications-gate-on-the-inbox-enumeration.md)).

**Permission.** Asked once, at the first launch (alert and sound). Refused, the app works the
same without banners; nothing in the app nags about it.

**New mail.** One banner per unread message the sync puts in an inbox, once that inbox's first
enumeration has finished — the first sync of an account, and a later re-download of the whole
inbox, never notify. Title: the sender's name (or address); body: the subject, or "No subject".
Banners of one thread stack together. More than five new messages in one sync pass of an
inbox give one banner instead: the account's address, "*N* new messages"; clicking it selects
that inbox.

**Show previews.** The app sets nothing of its own: with System Settings ▸ Notifications ▸
Nextcloud Mail ▸ Show previews set to *Never* (or *When Unlocked* on a locked Mac) the system
shows "New message" instead of the sender and subject: the categories set
`hiddenPreviewsBodyPlaceholder` and deliberately not `hiddenPreviewsShowTitle`, because the
title is the sender. That is the UserNotifications contract, not a measurement — an unsigned
development build is refused notification permission, so it could not be observed on screen.

**Actions** on a message banner: **Archive** (only when the account has an archive mailbox),
**Mark as read**, **Reply**. Archive and Mark as read are queued exactly as the toolbar's are,
so they work offline and show in the mirror at once. Reply brings the app forward and opens
the composer replying to the sender. Clicking the banner opens the message in its own window.

**When nothing is shown.** No banner while a main window is key *and* shows that inbox — the
inbox itself, Unified inbox or Priority inbox; the message is on screen already. Another
window key, another app frontmost or another mailbox selected: the banner is shown, even while
the app is frontmost. Read messages and drafts never notify.

**Nextcloud notifications.** Every five minutes per signed-in login the app reads the server's
notifications and keeps those of the Mail app (`app == "mail"`: mailbox nearly full, a
delegation). Each is shown once, as the server words it — title the subject, body the message —
and clicking it opens its link in the browser. Nothing is dismissed on the server: the web's
notification bell keeps it until the user dismisses it there, as the web client does. A server
without the notifications app (the route answers 404) is asked again only after the Mac wakes
or the app relaunches; any other failure keeps quiet until the next poll.

**Dock badge.** The unread count over every account's inbox — the same numbers the sidebar
shows next to each inbox, added up. No badge at zero.

## System integration (WS-42)

Nothing here draws its own window: every integration ends in a composer or a selection the
user already knows.

**Links the app opens.** The app registers `mailto:` and `ncmail:` (Info.plist).

| Link | Result |
| --- | --- |
| `mailto:…` (from any app, once Nextcloud Mail is the default mail app — WS-38's button) | A new composer with every field the URL carries (`to`, `cc`, `bcc`, `subject`, `body`), the account the one on screen |
| `ncmail://open/<Message-ID>` (WS-30's "Copy direct link") | The main window comes forward, the sidebar selects the message's mailbox and the list selects the message; in the list layout it opens in place. Several copies (one message in two mailboxes): the newest. No main window: the message opens in its own window. A Message-ID the mirror does not have: nothing happens |
| `ncmail://message/<id>` (a widget row) | The same selection, by local id |
| `ncmail://shared/<item>` (the Share extension) | A composer for the shared item |

A link that arrives with the launch is handled after the saved selection is restored, so the
link wins.

**Spotlight.** Messages appear as email items — subject as the title, the preview as the
description, the sender as author — and contacts as contact items with their addresses. The
newest 5 000 messages across every mailbox are in Spotlight, and every contact card (not
groups) of every signed-in login (ADR-0099). A message deleted, moved past the newest 5 000, or
a login signed out leaves Spotlight. Opening a message result selects it as a link does;
opening a contact selects its address book in that login's Contacts section, then the card.

**Widgets.** Two widgets, small, medium and large: **Important** and **Unread**, each listing
the newest messages of that kind across every inbox — sender (semibold when unread) and
subject, one line each. Small shows 2, medium 3, large 7. Clicking a row opens the message.
Empty: "No important messages" / "No unread messages"; before the app has ever written a
snapshot: "Open Nextcloud Mail to sign in". The widgets are as fresh as the last sync pass that
changed inbox rows (ADR-0071).

**Share extension.** "Nextcloud Mail" in the share menu of Finder, Safari and any app that
shares files, images, a web page or text. Choosing it shows nothing of its own: the files are
copied, and Nextcloud Mail opens a new composer with them attached, the page's URL and any text
in the body, and the shared title as the subject. If the app was not running and the hand-off
link is lost, the composer opens on the next launch.

**Services.** Services ▸ "New Nextcloud Mail message with selection": a new composer with the
selected text as the body. With nothing selected macOS greys the item out.
