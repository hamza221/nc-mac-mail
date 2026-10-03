<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# v2 roadmap: full Nextcloud Mail parity plus a built-in Contacts feature

## Context

v1 (WS-00–WS-15, milestones M0–M7) has shipped: reading and triage over a full local mirror. The user now wants a new roadmap whose goal is **full feature parity with the Nextcloud Mail web app**, using the manual QA checklist in https://github.com/nextcloud/mail/issues/13797 as the inventory, plus **a full Contacts feature built into the app** that feels native to it rather than like a separate app.

This plan produces documents only: ADRs, a parity matrix, the roadmap, the workstream table and one brief per workstream. No Swift code changes. The end state is that a v2 workstream can be handed to an agent exactly the way v1's were.

Choices already fixed by the user:
- Composer editor: **native NSTextView (TextKit 2) bridge** that this app owns.
- Contacts placement: **a section in the existing sidebar**, under the mail accounts.
- Contacts scope: **full Nextcloud Contacts parity**.
- Included edges: **native equivalents of web integrations** (Notification Center, dock badge, WidgetKit, Spotlight, default mail app, Share extension) and **AI features**.
- Excluded edges: **admin settings** (checklist §9) and **PGP/Mailvelope**.

## Approach

Every new Markdown file starts with the repo's SPDX header, exactly as existing docs do:

```
<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->
```

v1 content stays in place as history. Never rewrite a v1 brief or a v1 ADR body. The only change to a v1 ADR is ADR-0012's status line.

### Step 1 — Decision records 0064–0072

Write each file in `docs/decisions/` using the format in `docs/decisions/README.md` (Context / Decision / Consequences / Alternatives considered / Revisit when). Use date `2026-10-03`. Then add the index rows to `docs/decisions/README.md` after row 0063.

**Status rules:**
- 0064, 0065 and 0070 are decided by the user. Status `Accepted`; "Decided by: product owner, v2 planning".
- All the others are `Proposed`; "Decided by: v2 roadmap, to be confirmed by the owning workstream". The owning workstream flips the status to Accepted, or supersedes the record, in its own PR.

**ADR-0012 change:**
- Change its `**Status:**` line to `Superseded by ADR-0064`.
- Change its index row status to `Superseded by 0064`.

**What each record must say.** These are the decisions; write them as the Decision section and do not reopen them.

- **0064 — v2 is parity with the Nextcloud Mail web client's user surfaces, plus Contacts.** Supersedes 0012.
  - Scope: every user-facing item in the checklist of nextcloud/mail#13797 (§1–§8, §10), plus Nextcloud Contacts parity.
  - Excluded, each with its reason:
    - §9 admin settings: a server-administration surface the web admin panel already serves.
    - PGP/Mailvelope (§5.7 PGP row, §6.8 and §6.9 Mailvelope rows, the §7 Security Mailvelope card): a browser extension with no native equivalent chosen. The app shows an honest notice on PGP mail instead.
    - Debug-only items: "Clear cache", "Report this bug", "Download thread data for debugging".
    - Browser mechanics that have native replacements, mapped in `docs/product/parity.md`: history back/forward, Ctrl+click new tab, responsive breakpoints, beforeunload.
    - Server-only behaviour with no client surface: OCP Mail Provider, junk/ham reports, user migration, AI listeners.
  - Revisit when: a native OpenPGP implementation is wanted, or the client needs to administer servers.
- **0065 — The composer is a TextKit 2 `NSTextView` this app owns, serialising to HTML itself.**
  - What is serialised: the editor holds only what the user writes. The original being replied to or forwarded is kept as the server's sanitised HTML and attached at send time inside `<blockquote type="cite">`. It is shown read-only under the editor through the existing message web view. "Edit quoted text" imports it into the editor through `HTMLImporter`, accepting the loss.
  - Serialiser: our own `HTMLSerializer` over a fixed tag set. Not `NSAttributedString`'s HTML export, which emits CSS-heavy, Word-like markup.
  - Importer: our own `HTMLImporter`, built on `HTMLScanner.tokens(of:)` and `HTMLEntities` in `NextcloudMail/WebView/HTMLScanner.swift`. It never uses `NSAttributedString(html:)`, which runs WebKit and can fetch remote resources.
  - Upstreaming: the editor is designed to be upstreamed as `NCRichContenteditable` to NextcloudUI (deferred there to v1.1 per its ROADMAP), so the code must not depend on mail types.
  - Alternatives that lost: a WKWebView contenteditable editor (a second scriptable web view to secure, less Mac-like); waiting for the library.
  - Revisit when: NextcloudUI ships `NCRichContenteditable`.
- **0066 — Drafts are local rows synced to the server's draft API; sending goes through the server outbox, driven by its own actor, not the mutation queue.**
  - Resolves ADR-0005's note that a queued send deserves its own record.
  - Lifecycle: `draft` rows are authoritative locally. `OutboxSender` creates and updates server drafts (`POST/PUT /api/drafts`) 5 s after the last edit. On composer close it calls `POST /api/drafts/move/{id}`.
  - Sending: send = a local 10-second undo window, then attachment uploads (`POST /api/attachments`), then `POST /api/outbox` with `draftId`, then `POST /api/outbox/{id}` unless `sendAt` is set.
  - Scheduled sends stay on the server, and the Outbox view reads mirrored `GET /api/outbox` rows.
  - Why not the OCS `message/send`: limited to 5 per 100 s and has no attachments.
  - Revisit when: the server offers idempotent send keys.
- **0067 — Server-computed results are cached rows.**
  - Applies to: thread summaries, smart replies, translations, itinerary and event-data suggestions, quota, Sieve script text, supplemental recipient suggestions, Files listings, Smart Picker results, Teams lists.
  - Mechanism: an actor in `NCMailSync` requests the result and writes it into a table; the view observes the table and shows a pending state until the row exists.
  - This keeps "the network only writes to the database" without exceptions.
  - Cost: a table per result kind and stale rows. Each row carries `fetchedAt`, and each owning workstream sets its own expiry.
- **0068 — Settings the server must validate are online-only commands.** This is the one deliberate exception to "queue every mutation", and the record must say it is one.
  - Applies to: mail-server credentials, Sieve connection, Sieve script, mail filters, autoresponder, S/MIME import, delegation, account creation, and the account connection test.
  - Mechanism: a `SettingsCommands` actor in `NCMailSync` performs the request. On success it writes the server's resulting state into the store. It returns `CommandOutcome` (success, or a `MailError` with the server message).
  - What the view awaits: only the outcome, to show a spinner or an error (for example 422 Sieve syntax errors). It never renders response data; data is read from the store.
  - Why: queueing these offline would accept input the server will reject hours later, with nobody there to fix it.
  - Everything else (tags, text blocks, quick actions, preferences, mailbox create/rename/delete, internal addresses, trusted domains, signatures, aliases) goes through the mutation queue as new operation kinds.
- **0069 — Contacts use the same database and the same five modules, keyed by Nextcloud login.**
  - Placement: the DAV client goes in `NCMailNet/DAV`; vCard and iCalendar value types in `NCMailCore/Contacts` and `NCMailCore/Calendar`; tables in `NCMailStore`; sync in `NCMailSync/Contacts`; UI in `NextcloudMail/Views/Contacts`.
  - No new package: "No network call outside NCMailNet" (AGENTS.md) forbids a self-contained contacts package with its own networking, and one database lets autocomplete join contacts against mail addresses.
  - Keying: contacts belong to an `AccountSession` (server and login, `NextcloudMail/App/AccountSession.swift`), not to a mail `account` row, because one Nextcloud login has many mail accounts and one set of address books.
  - vCard handling: our own lossless vCard 3.0/4.0 parser and serialiser that preserves unknown properties and parameters. Not `CNContactVCardSerialization`, which drops `X-` properties and loses data on round trip.
  - Sync protocol: RFC 6578 `sync-collection` with sync tokens. Writes use `If-Match`. On 412, refetch and reapply the locally edited properties.
- **0070 — Contacts appear as a sidebar section, under the mail accounts.**
  - Layout: one `List(selection:)` sidebar. Per Nextcloud login there is a "Contacts" section listing All contacts, Favorites, each enabled address book, contact groups, Teams (when available) and Recently contacted.
  - Columns: picking one turns the content column into the contact list and the detail column into the contact card.
  - Why: the user wants Contacts to feel part of the app. A second window and a module switcher both lost.
- **0071 — Widgets read a snapshot file in the app group, never the database.**
  - The app writes `widget-snapshot.json`, holding the latest ≤ 7 Important and ≤ 7 Unread inbox items, into the app-group container. It writes it after every sync pass that changes inbox rows, then calls `WidgetCenter.shared.reloadAllTimelines()`.
  - Why: avoids moving the GRDB database and its WAL into a container shared across processes.
  - Privacy: the snapshot holds subjects and senders. It lives in the sandboxed group container (ADR-0006 already accepts envelopes on disk).
- **0072 — Recipient autocomplete is local-first.**
  - Sources: the contacts mirror (all enabled address books, including the system address book), contact groups, own identities and aliases, and addresses from mirrored mail.
  - Server supplement: `GET /api/autoComplete?term=` runs only after local results are shown. Its results land in a `recipientSuggestion` cache table per ADR-0067, so Nextcloud groups and collected addresses still appear.
  - Ranking: own identities last, then contacts by recent interaction, then mail-derived addresses by frequency.

### Step 2 — Parity matrix `docs/product/parity.md`

**Header:**
- First line: `*Every user-facing behaviour of the Nextcloud Mail web client and Nextcloud Contacts, mapped to the workstream that delivers it or the ADR that excludes it.*`
- Then one paragraph citing the checklist source: https://github.com/nextcloud/mail/issues/13797, opened 2026-10-02, against nextcloud/mail 5.12.

**Mail table:**
- Columns: `| § | Area | Owner | Native mapping / note | Status |`.
- One row per checklist subsection §1.1 to §10, plus one row for the appendix flags table.
- Status is `Planned`, `v1` (already shipped) or `Excluded (ADR-0064)`.
- The `v1` rows are verified at the end by WS-44.

**Mapping.** Write these rows exactly. Owners are the WS numbers from Step 4.

| § | Owner | Note |
| --- | --- | --- |
| 1.1–1.5 Setup, account form, OAuth, errors | WS-40 | Native setup window; Google/Microsoft OAuth through `ASWebAuthenticationSession` |
| 2.1 Start-up and routes | WS-25 | Start mailbox restore; deep links become `ncmail://open/<Message-ID>` (WS-42); browser history → native window/selection restoration; Ctrl+click new tab → "Open in New Window" |
| 2.1 Session expiry | v1 | 401 modal already exists |
| 2.2 Background sync | v1 + WS-21 | Outbox refresh in WS-21; cadence is v1's |
| 2.3 Desktop notifications | WS-41 | Notification Center; suppressed while the window is key (fixes the web ⚠) |
| 2.4 Layout and appearance prefs | WS-29 (behaviour), WS-38 (settings UI) | Vertical, horizontal and list layouts; compact mode; sort order; favorites up |
| 2.5 Responsive, dark mode, RTL | DoD | Responsive → native window resizing (excluded as browser mechanics); dark mode and RTL are definition-of-done gates; composer RTL in WS-20 |
| 2.6 Keyboard shortcuts | WS-31 | Adds `C`/`⌘N` compose and `⌘⇧D` send; ⚠ unbound keys become bound |
| 2.7 Accessibility | DoD | — |
| 3.1–3.3 Navigation, account menu, folder menu | WS-28 | — |
| 3.4 Drag and drop | WS-28 (drop targets), WS-29 (drag source) | — |
| 4.1 States and grouping | WS-29 | — |
| 4.2 Priority inbox, favorites | WS-28 (entries), WS-29 (sections) | Important/Other are local queries over `isImportant` |
| 4.3 Envelope row | WS-29 | — |
| 4.4 Envelope menu | WS-29 (menu), WS-31 (actions) | — |
| 4.5 Multi-select and bulk | WS-29, WS-31 | Native adds `⌘A` |
| 4.6 Search | WS-32 | Local FTS; server body search unnecessary |
| 4.7 Folder pickers | WS-31 | — |
| 4.8 Tags | WS-31 | — |
| 4.9 Outbox | WS-23 (engine), WS-27 (view) | — |
| 5.1–5.4 Thread, header, action bar, message menu | WS-30 | — |
| 5.5 Reply area, smart replies, follow-up | WS-30 | Prefill through WS-27 |
| 5.6 Unsubscribe | WS-30 | — |
| 5.7 Body rendering | WS-30 | PGP row → notice only (ADR-0064) |
| 5.8 Translation | WS-30 | — |
| 5.9 Calendar, iMIP, tasks, itineraries | WS-34 | — |
| 5.10 Attachments | WS-30, WS-33 | Viewer → Quick Look |
| 5.11 Recipient bubbles | WS-26 | — |
| 5.12 Printing | v1 + WS-30 | Whole-thread print in WS-30 |
| 6.1, 6.3, 6.4, 6.6–6.9 Composer | WS-27 | Sending in WS-23; Files attachments and share links in WS-33 |
| 6.2 mailto | WS-42 (handler), WS-27 (parser) | Default mail app via `NSWorkspace` |
| 6.5 Editor | WS-20 | — |
| 6.8, 6.9 Mailvelope rows | Excluded (ADR-0064) | — |
| 7 App settings, 7.1 Text blocks, 7.2 S/MIME | WS-38 | PKCS#12 converted locally |
| 7 Security Mailvelope card | Excluded (ADR-0064) | — |
| 8, 8.1–8.8 Account settings | WS-39 | — |
| 9 Admin settings | Excluded (ADR-0064) | — |
| 10 App menu | — | Native: Dock; nothing to build |
| 10 Dashboard widgets | WS-42 | WidgetKit |
| 10 Unified search | WS-42 | Spotlight |
| 10 Notifications app | WS-41 | Quota and delegation notices via the notifications OCS API |
| 10 mailto, error template | WS-42, WS-30 | — |
| 10 OCP Mail Provider, junk reports, user migration, AI listeners | Excluded (ADR-0064) | Server-only; their visible output is covered by WS-29 and WS-30 |
| 10 Contacts interaction, drafts cleanup | WS-23 | Verify the server does it on send |
| 10 Context Chat | WS-38 | Preference toggle |
| 10 Provisioning middleware | WS-28, WS-39 | Disabled provisioned accounts; locked sections |
| "Not present in the code" list | WS-29, WS-41 | Native adds select-all and a dock badge; the right-click menu and offline indicator are v1 |
| Appendix flags | WS-16 | Records how each flag is discovered without the web page's initial state |

**Contacts table**, same columns. Source: https://docs.nextcloud.com/server/latest/user_manual/en/groupware/contacts.html plus the Contacts app. Rows:
- Add contact, edit, remove, every vCard field → WS-35.
- Contact picture: upload, remove, full size, download, social-network fetch → WS-35.
- Favorites → WS-35.
- Contact groups → WS-35.
- Multi-select batch delete → WS-36.
- Merge two contacts → WS-36.
- vCard import (3.0/4.0) → WS-36.
- Address books: create, rename, enable/disable, share, export, delete, copy CardDAV URL → WS-36.
- Contacts settings: sort order, social avatar auto-update → WS-36.
- Teams: create, members, roles, options → WS-37, gated on the Circles app being present.
- Shared items → WS-37.
- Organisation chart → WS-37.
- Mail↔Contacts integration (autocomplete, sender cards, add to contact, recent mail with a contact, contact photos as avatars) → WS-26 and WS-24.

### Step 3 — Roadmap `docs/delivery/roadmap.md`

**Restructure:**
- Retitle the existing table section `## v1 — shipped (M0–M7)` and keep its rows unchanged.
- Add `## v2 — parity (M8–M16)` with this table (columns `M | Milestone | Workstreams | Demonstrable`):

| M | Milestone | Workstreams | Demonstrable |
| --- | --- | --- | --- |
| M8 | It speaks the whole API | WS-16, WS-17, WS-18, WS-19, WS-20 | Every new endpoint decodes a recorded fixture; a CardDAV `sync-collection` against the live server lists the user's address books; the editor playground round-trips the fixed tag set through `HTMLSerializer`/`HTMLImporter` unchanged |
| M9 | It mirrors everything | WS-21, WS-22, WS-23, WS-24, WS-25 | Tags, aliases, signatures, text blocks and preferences appear in the database from a real account; the contacts mirror fills and survives airplane mode; a draft row created in a test sends through `OutboxSender` and arrives in the inbox |
| M10 | It sends | WS-26, WS-27 | Compose, reply all, forward with attachments, send later, undo send; written offline, sent on reconnect; recipients autocomplete offline |
| M11 | It works like the web client | WS-28–WS-33 | Folder management, unified/priority inbox, tags, snooze, quick actions, search dialog, Files save/attach, translation and smart replies against the live server |
| M12 | It knows people | WS-35, WS-36, WS-37 | Edit a contact offline, see it in the web Contacts app after reconnect; import a vCard file; merge two contacts |
| M13 | It schedules | WS-34 | Accept an invitation and see it in Nextcloud Calendar; import an itinerary |
| M14 | It configures | WS-38, WS-39, WS-40 | Add an IMAP account, set an autoresponder, save a filter, import an S/MIME certificate — all from the app |
| M15 | It belongs on the Mac | WS-41, WS-42 | A notification with Archive works; the dock badge counts unread; Spotlight finds a message and a contact; a `mailto:` link in Safari opens the composer; the Unread widget shows mail |
| M16 | It is at parity | WS-43, WS-44 | Every row in `docs/product/parity.md` is `Done` with evidence or `Excluded` with an ADR |

**Prose sections:**
- Replace "Order, and what it buys" with a v2 version:
  - M8–M9 are foundations and engines with nothing visible, exactly as M1–M3 were.
  - WS-20 (editor) starts in wave 1 because it depends on nothing and is the longest single item.
  - Contacts sync (WS-24) lands in M9 so that composer autocomplete (M10) is local from day one.
- Replace "Parallelism":
  - Wave 1 has five agents.
  - Wave 2 has four, then WS-25 integrates them.
  - Wave 3 has up to eight.
  - The graph in workstreams.md remains the authority.
- Replace "What is not on this roadmap" with: admin settings, PGP, debug-only tools, citing ADR-0064; then release engineering (unchanged paragraph).

### Step 4 — Workstreams `docs/delivery/workstreams.md`

**Top matter:**
- Rewrite the opening sentence: "Forty-five units of work: WS-00–WS-15 shipped v1; WS-16–WS-44 are v2."
- Rename the existing sections to `## v1 dependency graph` and `## v1 workstreams` (content unchanged).

**Add `## v2 dependency graph`**, as a fenced text block in the same style:

```
WAVE 1 (M8)  WS-16 API surface   WS-17 DAV + vCard/iCal   WS-18 store v2   WS-20 editor   WS-19 harness v2 (→ continuous)
                 │                     │                      │
WAVE 2 (M9)  WS-21 server-state mirror  WS-22 queue v2 + commands  WS-23 drafts/outbox engine  WS-24 contacts+calendars mirror
                 └──────────────┬──────────────┴───────────────┬────────────┘
                                ▼                              ▼
                         WS-25 app shell v2  (integrates every wave-2 engine)
                                │
WAVE 3 (M10–M11)  WS-26 people  WS-27 composer  WS-28 sidebar  WS-29 list  WS-30 message  WS-31 triage  WS-32 search  WS-33 Files
                                │
WAVE 4 (M12–M14)  WS-34 calendar  WS-35 contacts  WS-36 address books  WS-37 teams  WS-38 app settings  WS-39 account settings  WS-40 setup
                                │
WAVE 5 (M15)      WS-41 notifications/badge   WS-42 system integration
STANDING          WS-43 feedback v2 (∞)   WS-44 parity audit (lands last)
```

**Add `## v2 workstreams`** with the same table columns (`ID | Title | Depends on | Owns | Size`). Each ID links to its brief. Rows, with ownership exactly as listed:

| ID | Title | Depends on | Owns | Size |
| --- | --- | --- | --- | --- |
| WS-16 | Mail API surface: endpoints, models, flag discovery | — | `NCMailNet/Endpoints/**`, `NCMailNet/Client/**`, `NCMailCore/Models/**` | L |
| WS-17 | DAV client, vCard and iCalendar | — | `NCMailNet/DAV/**`, `NCMailCore/Contacts/**`, `NCMailCore/Calendar/**` | L |
| WS-18 | Store v2: migrations, DAOs, observations | — | `NCMailStore/**` except `Search/**` | XL |
| WS-19 | Test harness v2 | — | `Packages/NCMailTestSupport/**`, `Scripts/record-fixtures.sh` | M |
| WS-20 | Rich text editor | — | `NextcloudMail/Editor/**` | XL |
| WS-21 | Server-state mirror | 16, 18 | `NCMailSync/Sync/**`, `NCMailSync/Mirror/**` | L |
| WS-22 | Queue v2 and settings commands | 16, 18 | `NCMailSync/Operations/**`, `NCMailSync/Commands/**` | L |
| WS-23 | Drafts and outbox engine | 16, 18 | `NCMailSync/Outbox/**` | L |
| WS-24 | Contacts and calendars mirror | 17, 18, 22 | `NCMailSync/Contacts/**`, `NCMailSync/Calendar/**` | XL |
| WS-25 | App shell v2 | 21, 22, 23, 24 | `NextcloudMail/App/**`, `Theme/**`, `Status/**`, `MailSymbol.swift` | M |
| WS-26 | People: recipient suggestions and contact cards | 24, 25 | `NextcloudMail/Views/People/**` | M |
| WS-27 | Composer and outbox view | 20, 22, 23, 25, 26 | `NextcloudMail/Views/Composer/**`, `NextcloudMail/Views/Outbox/**` | XL |
| WS-28 | Sidebar and mailbox management | 21, 22, 25 | `NextcloudMail/Views/Sidebar/**`, `NCMailCore/MailboxTree.swift` | L |
| WS-29 | Message list parity | 21, 22, 25 | `NextcloudMail/Views/MessageList/**` | L |
| WS-30 | Message view parity | 21, 22, 25, 26 | `NextcloudMail/Views/Message/**`, `NextcloudMail/WebView/**` | XL |
| WS-31 | Triage parity: tags, snooze, quick actions, shortcuts | 22, 25 | `NextcloudMail/Actions/**`, `NextcloudMail/Commands/**` | L |
| WS-32 | Search parity | 18, 25 | `NCMailStore/Search/**`, `NextcloudMail/Views/Search/**` | M |
| WS-33 | Files picker and Files actions | 17, 18, 25 | `NextcloudMail/Views/Files/**`, `NCMailSync/Files/**` | M |
| WS-34 | Calendar integration | 24, 30 | `NextcloudMail/Views/Calendar/**` | L |
| WS-35 | Contacts: browse, view, edit | 24, 25 | `NextcloudMail/Views/Contacts/**` except `AddressBooks/**`, `Teams/**` | XL |
| WS-36 | Address books, import/export, merge, batch | 35 | `NextcloudMail/Views/Contacts/AddressBooks/**` | L |
| WS-37 | Teams, shared items, org chart | 35 | `NextcloudMail/Views/Contacts/Teams/**` | M |
| WS-38 | App settings parity | 20, 21, 22 | `NextcloudMail/Views/Settings/**` except `Account/**` | L |
| WS-39 | Account settings parity | 20, 21, 22 | `NextcloudMail/Views/Settings/Account/**` | XL |
| WS-40 | Mail account setup | 22, 25 | `NextcloudMail/Views/AccountSetup/**` | L |
| WS-41 | Notifications, dock badge, Nextcloud notifications | 25 | `NextcloudMail/Notifications/**` | M |
| WS-42 | System integration: default mail app, mailto, Spotlight, widgets, Share extension, Services | 25, 27 | `NextcloudMail.xcodeproj/**`, new extension target folders, `NextcloudMail/System/**` | L |
| WS-43 | Feedback v2 | all | `docs/feedback/**` | S |
| WS-44 | Parity audit | all | `docs/product/parity.md` status column | M |

**Add `## v2 file ownership`.** List the deltas from the v1 table:
- `NCMailCore/Sources/**` is owned by WS-16, except `Contacts/**` and `Calendar/**` (WS-17) and `MailboxTree.swift` (WS-28).
- `NCMailNet/Sources/Auth/**` stays with WS-01's code and has no v2 owner; any change is requested from WS-25.
- `NextcloudMail.xcodeproj/**` and `Package.swift` files are owned by WS-42. Any other workstream needing a manifest change requests it from WS-42. The one exception is WS-17 and WS-24, which add no package because the folders already sit inside existing targets.

**Standing exceptions** (each is the only cross-boundary edit allowed):
1. WS-35 adds the single line embedding `ContactsSidebarSection` into `NextcloudMail/Views/Sidebar/SidebarView.swift`.
2. WS-27 adds the single line registering `ComposerScene()` in `NextcloudMail/App/NextcloudMailApp.swift`.
3. Any workstream may **append** cases to `MailSymbol.swift`; renaming or removing cases stays with WS-25.
4. Any workstream may **append** its own fixture files under `NCMailTestSupport`'s fixture directory, recorded with `Scripts/record-fixtures.sh`.

Report template and working agreement are unchanged; state that they apply to v2.

### Step 5 — Briefs `docs/delivery/briefs/WS-16-*.md` … `WS-44-*.md`

**File names** (`WS-NN-<slug>.md`), in order: `WS-16-api-surface`, `WS-17-dav-and-formats`, `WS-18-store-v2`, `WS-19-test-harness-v2`, `WS-20-rich-text-editor`, `WS-21-server-state-mirror`, `WS-22-queue-v2-and-commands`, `WS-23-drafts-and-outbox`, `WS-24-contacts-and-calendars-mirror`, `WS-25-app-shell-v2`, `WS-26-people`, `WS-27-composer`, `WS-28-sidebar-v2`, `WS-29-message-list-v2`, `WS-30-message-view-v2`, `WS-31-triage-v2`, `WS-32-search-v2`, `WS-33-files`, `WS-34-calendar`, `WS-35-contacts`, `WS-36-address-books`, `WS-37-teams`, `WS-38-app-settings`, `WS-39-account-settings`, `WS-40-account-setup`, `WS-41-notifications`, `WS-42-system-integration`, `WS-43-feedback-v2`, `WS-44-parity-audit`.

**Brief shape.** Every brief follows `docs/delivery/briefs/README.md`: title `# WS-NN — <title>`, the bold wave/size line, then Goal, Before you start, You own, Build, Acceptance, Out of scope, Report. Copy WS-10's tone: rules that are easy to get wrong go in Build, as a bullet list.

**"Before you start" opens every brief with:**
1. `AGENTS.md`
2. `architecture/overview.md`
3. ADR-0003
4. ADR-0064
5. the brief's own rows in `product/parity.md`

Then the brief-specific documents listed below.

**Every brief's Build section also contains:**
- "Your first commit updates `docs/product/ux-spec.md` (UI workstreams) or the architecture document named below (engine workstreams) with the screens/behaviour you will build, so reviewers check against a written spec." This replaces writing the v2 UX spec centrally.
- "Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the evidence (test name or manual check) in the note column."

**Out of scope** in every brief names the owning WS for each neighbouring concern, taken from the Step 4 table.

**Update `docs/delivery/briefs/README.md`:**
- Append rows WS-16–WS-44 with their wave (1, 2, 3, 4, 5, ∞, end).
- Add rule 7: "**Server-computed results are rows** (ADR-0067); **server-validated settings are commands** (ADR-0068)."

#### Per-brief content

Each item below is the brief's Goal / Build contract / Acceptance. Signatures are contracts other workstreams call; write them verbatim.

**WS-16 Mail API surface** (wave 1, L). Goal: every user-facing route in `plan/API.md` that the app does not call yet, decoded against a recorded fixture.
- Build: `Endpoint` factories in `Endpoints.swift` for every route in these `plan/API.md` sections:
  - Accounts: create, PUT, PATCH, DELETE, signature, smime-certificate, quota, test.
  - Aliases; Auto configuration; Mailboxes: create, PATCH, DELETE, clear, read, stats, repair.
  - Messages: source, export, itineraries, dkim, tags, snooze/unsnooze, mdn, save attachment to Files, attachments zip, file, smartreply.
  - Threads: snooze, unsnooze, summary, eventdata. Drafts; Outbox; Attachments upload (multipart); Tags.
  - autoComplete and contactIntegration; Preferences PUT; trusted senders domain type; internal addresses.
  - Sieve and filters; Out of office; Follow-up; Quick actions and action steps; Text blocks and shares.
  - S/MIME certificates; Delegation; Mailing list unsubscribe; `POST /api/oauth/state`.
  - Admin routes are excluded (ADR-0064).
- Also these non-Mail routes, each marked "unverified — confirm against the live server first" in the brief, with the confirmed path written to `docs/reference/api-payloads.md`:
  - core translation (OCS `translation/languages` and `translation/translate`, or TaskProcessing if that is what the server offers);
  - Smart Picker reference providers and search;
  - notifications OCS v2 list and delete;
  - files_sharing OCS share-link creation;
  - Circles/Teams OCS.
- `MailClient` gains `upload(_ endpoint:, multipart:)` for `POST /api/attachments` and S/MIME import. Retryability per endpoint follows `networking.md` (sends, moves and creates are never retried).
- **Flag discovery:** record, in a new `docs/reference/server-flags.md`, how the client learns each appendix flag without the web page's initial state:
  - `allow-new-accounts`, `disable-scheduled-send`, `disable-snooze`, `llm_*`, `context_chat_available`, `importance_classification_default`, `enable-system-out-of-office`, `attachment-size-limit`, `google-oauth-url`, `microsoft-oauth-url`.
  - Candidate sources: capabilities, preferences, account payload fields, or probing.
  - Contingency (written in the brief): a flag with no API source is treated as "feature on". Its server error is surfaced in the UI as the server's message, and the gap is appended to `docs/feedback/server-findings.md`.
- Acceptance: every new endpoint has a decode test against a recorded fixture; `server-flags.md` covers every appendix flag.

**WS-17 DAV client, vCard, iCalendar** (wave 1, L). Goal: a CardDAV/CalDAV/WebDAV client and lossless formats, with no UI.
- Build in `NCMailNet/DAV/`:
  - `DAVClient` (a `Sendable` struct using the existing `MailTransport` and credentials).
  - `propfind(_ url:, depth:, properties:)`, `report(_ url:, body:)`, `syncCollection(_ url:, token:)` returning `(changed: [DAVResource], removed: [URL], newToken: String)`.
  - `addressbookMultiget`, `calendarMultiget`, `put(_ url:, data:, contentType:, ifMatch:)` returning the ETag, `delete(_ url:, ifMatch:)`, `mkcolExtended`, `proppatch`.
  - `share(_ url:, with:, readOnly:)` (Nextcloud `oc:share` POST).
  - Principal discovery: current-user-principal → addressbook-home-set and calendar-home-set.
  - XML via Foundation `XMLParser`; no new dependency (DoD).
- Build in `NCMailCore/Contacts/`: `VCard` (ordered properties preserving group, name, parameters and raw value; typed accessors for N, FN, NICKNAME, ORG, TITLE, EMAIL, TEL, ADR, URL, IMPP, X-SOCIALPROFILE, BDAY, ANNIVERSARY, NOTE, RELATED, CATEGORIES, PHOTO, UID, REV), `VCardParser` (3.0 and 4.0, line unfolding, quoted-printable for 2.1-style imports), `VCardSerializer` (re-emits unknown properties byte-equivalent).
- Build in `NCMailCore/Calendar/`: `ICalendar` with VEVENT/VTODO/VTIMEZONE read/write sufficient for iMIP REQUEST/REPLY/CANCEL, PARTSTAT and X-RESPONSE-COMMENT, plus event/task creation.
- Acceptance:
  - Parsing then serialising each recorded vCard fixture yields identical bytes, modulo line folding.
  - `syncCollection` is tested against recorded REPORT responses, including a 507 truncated sync.
  - Principal discovery works on the live server (manual check in the PR).

**WS-18 Store v2** (wave 1, XL). Goal: every table v2 needs, as a `v2` migration that reproduces the updated `docs/reference/schema.sql`.
- Build: one migration `v2` (never edit `v1`, see `Packages/NCMailStore/Sources/NCMailStore/Migrations.swift`), adding tables for:
  - `draft`, `draftRecipient`, `draftAttachment`, `outboxMessage`;
  - `alias`; account columns for editorMode, signatureAboveQuote, trashRetentionDays, searchBody, classificationEnabled, imipCreate, order, and the flags discovered by WS-16;
  - `preference`, `textBlock`, `textBlockShare`, `quickAction`, `quickActionStep`, `trustedSender`, `internalAddress`, `delegation`, `smimeCertificate`;
  - `sieveState` (connection, script text, filters JSON, out-of-office JSON);
  - `serverResult` (kind, key, payloadJSON, fetchedAt; ADR-0067), `recipientSuggestion`, `filesListing`, `smartPickerResult`;
  - `addressBook`, `contact` (raw vCard plus extracted display columns and ETag), `contactEmail`, `contactPhone`, `contactGroupMember`;
  - `contactSearch` (FTS5, with a delete trigger per ADR-0024);
  - `calendar`, `team`, `teamMember`;
  - `snooze` (messageId, until).
- Tags reuse the existing `tag`/`messageTag`.
- Observed tables are rowid tables (ADR-0025).
- DAOs and `AsyncSequence` observations follow ADR-0034 (no GRDB type crosses the boundary).
- Column-level design is this workstream's; anything a later workstream needs is requested through its report and added as `v3`, `v4`, ….
- Acceptance: the migration test matches `schema.sql`; deleting a Nextcloud login leaves no orphans in any table, including contacts and FTS; every table has a query test.

**WS-19 Test harness v2** (wave 1, continuous, M). Goal: fake transport and recorder coverage for every new route and for DAV.
- Build:
  - `FakeTransport` matchers for DAV methods (PROPFIND, REPORT, MKCOL, PROPPATCH) and multipart bodies.
  - `Scripts/record-fixtures.sh` targets for each WS-16 route and for CardDAV/CalDAV.
  - A documented rule in `docs/delivery/testing-strategy.md`: send fixtures are recorded by sending to the test account's own address only.
- Acceptance: each new fixture is recorded from the live server; nothing is hand-written.

**WS-20 Rich text editor** (wave 1, XL). Goal: a native rich text editor that produces web-client-compatible HTML (ADR-0065).
- Build in `NextcloudMail/Editor/`:
  - `ComposerTextView: NSTextView` (TextKit 2).
  - `RichTextEditor: NSViewRepresentable`, bound to `EditorDocument` (an `@Observable` wrapper over `NSTextStorage`), with `mode: .plain | .rich`.
  - `HTMLSerializer.html(from: NSAttributedString) -> String`.
  - `HTMLImporter.attributedString(fromHTML: String, baseFont: NSFont) -> NSAttributedString` (reusing `HTMLScanner.tokens(of:)` and `HTMLEntities.decode`).
  - `PlainTextSerializer.text(from:)`.
  - The fixed tag set: p, br, strong, em, u, s, sub, sup, h1–h3, ul/ol/li, blockquote, a[href], img[src=data:… width], span[style=color|background-color|font-family|font-size], div/p[dir], text-align.
- Toolbar parity with §6.5: heading, font family, size 9–24, B/I/U/S, colour, sub/sup, background, image, alignment, LTR/RTL, lists, quote, link, remove format, find and replace (`NSTextFinder`), source view (an editable HTML text view re-imported on toggle back), undo/redo.
- Triggers via the same API:
  - `:` emoji (NextcloudUI `NCEmojiPalette`);
  - `@` mention (asks a `MentionProvider` protocol, implemented later by WS-26);
  - `!` text block (`TextBlockProvider` protocol, implemented by WS-27);
  - `/` Smart Picker (`SmartPickerProvider` protocol, implemented by WS-27).
- Paste: the readable pasteboard types are restricted to RTF, RTFD, plain text, images and HTML. HTML goes through `HTMLImporter` only, so pasting never makes a network request. Pasted or dropped files are attachments, emitted through an `onFileDrop` callback.
- Turning formatting off asks "Turn off and remove formatting" / "Keep formatting".
- Ships with a debug-only `EditorPlayground` view.
- Acceptance:
  - HTML → editor → HTML is a fixed point for every construct in the tag set (unit tests).
  - Pasting from Safari makes no network request (manual check with the network monitor).
  - VoiceOver reads the toolbar.
- Report: the library-feedback entry proposing this as `NCRichContenteditable`.

**WS-21 Server-state mirror** (wave 2, L). Goal: every piece of server state v2 shows is mirrored into the store on a schedule, never fetched by a view.
- Build:
  - Envelope tag mapping into `messageTag` (currently missing in `Mirror/MirrorMapping.swift`).
  - Account settings, aliases and signatures (stop writing nil signatures).
  - Preferences.
  - Text blocks and shares, quick actions and steps, trusted senders (individual and domain), internal addresses, delegations, S/MIME certificates.
  - Sieve state when enabled, quota, outbox list (every 60 s while non-empty), follow-up re-check (`POST /api/follow-up/check-message-ids` when Priority inbox is shown).
  - Cadence: refreshed at launch, at every deep reconcile, and when Settings opens.
  - `ServerResultFetcher` actor implementing ADR-0067 for summaries, smart replies, translations, itineraries, event data and autoComplete supplements, with `request(kind:key:)` returning immediately.
- Acceptance: each mirrored kind has a fake-transport test including a failure path; airplane mode keeps the last mirrored state visible.

**WS-22 Queue v2 and settings commands** (wave 2, L). Goal: every offline-capable v2 mutation is a queue kind; every server-validated setting is a command (ADR-0068).
- New `MailOperation` / `OperationKind` cases:
  - tags: `setTag`, `unsetTag`, `createTag`, `updateTag`, `deleteTag`;
  - snooze: `snooze`, `unsnooze`, `snoozeThread`, `unsnoozeThread`;
  - mailboxes: `createMailbox`, `renameMailbox`, `moveMailbox`, `deleteMailbox`, `setMailboxSubscribed`, `setMailboxSyncInBackground`, `clearMailbox`, `markMailboxRead`;
  - settings: `setPreference`, `patchAccount`, `setSignature`, `createAlias`, `updateAlias`, `deleteAlias`, `setAliasSignature`;
  - text blocks: `createTextBlock`, `updateTextBlock`, `deleteTextBlock`, `shareTextBlock`, `unshareTextBlock`;
  - quick actions: `createQuickAction`, `updateQuickAction`, `deleteQuickAction`, `upsertActionStep`, `deleteActionStep`;
  - addresses: `addInternalAddress`, `removeInternalAddress`, `trustDomain`;
  - mail actions: `sendMDN`, `unsubscribe`, `saveToFiles`;
  - contacts and calendars: `contactPut`, `contactDelete`, `addressBookCreate`, `addressBookUpdate`, `addressBookDelete`, `addressBookShare`, `calendarPut`.
  - Each case has a `before` snapshot for undo and discard, as the existing kinds do.
  - Local identity for created rows follows ADR-0033.
- `actor SettingsCommands` in `NCMailSync/Commands/`, with `func run(_ command: SettingsCommand) async -> CommandOutcome`, where `SettingsCommand` covers:
  - `updateMailServer`, `testConnection`, `configureSieve`, `saveSieveScript`, `saveFilters`, `saveOutOfOffice`, `followSystemOutOfOffice`;
  - `importSMIME(pem:privateKey:)`, `deleteSMIME`, `setAliasCertificate`;
  - `delegate`, `revokeDelegation`;
  - `createAccount`, `deleteAccount`;
  - `repairMailbox`, `startOAuth`.
- Acceptance: every kind survives quit and drains on reconnect (fake transport); a 422 from `saveSieveScript` comes back as `CommandOutcome.failure` carrying the server's message.

**WS-23 Drafts and outbox engine** (wave 2, L). Goal: ADR-0066, implemented.
- Build `actor OutboxSender` in `NCMailSync/Outbox/`:
  - `saveDraft(_ draftId: Int64)` (debounced 5 s server sync);
  - `closeDraft(_:)` (`drafts/move`);
  - `discardDraft(_:)`;
  - `send(draftId: Int64, sendAt: Date?) async throws` (enters a 10 s undo window persisted in the row, so a quit during the window sends on next launch only if the window has elapsed);
  - `undoSend(draftId:)`, `sendNow(outboxId:)`, `copyToSent(outboxId:)`, `deleteOutbox(outboxId:)`.
- Ordering: attachment uploads finish before `POST /api/outbox`. A failed upload leaves the draft in `failed` state with the reason.
- After sending: the Sent mailbox gets a `syncNow`. The interaction "recently contacted" and the draft cleanup are server behaviour; verify both and record them in `api-payloads.md`.
- Offline: a send waits in `queued` until online.
- Acceptance: compose → send → message in Sent (live); undo within 10 s leaves no server trace; offline send goes out on reconnect; scheduled send appears in the outbox list.

**WS-24 Contacts and calendars mirror** (wave 2, XL). Goal: ADR-0069. A complete, offline-editable mirror of every address book, plus the calendar list, per Nextcloud login.
- Build `actor ContactsSync` in `NCMailSync/Contacts/`:
  - discovery, address book list (including enabled state, read-only, shared-by, sync token);
  - `sync-collection` loop (every 10 min, and on wake);
  - multiget batches of 100;
  - writes via the queue kinds from WS-22 with `If-Match`;
  - 412 → refetch, reapply local edits per property, retry once, otherwise surface a conflict row.
- Contact photos are written into the existing `avatar` table by email, ahead of server avatars (ADR-0061 names this path).
- Build `actor CalendarListSync` in `NCMailSync/Calendar/`: calendars with components (VEVENT/VTODO), writability, colour and the default schedule calendar.
- Social avatar fetch: the Contacts app route, unverified — confirm first.
- Acceptance:
  - A 2,000-contact system address book mirrors in under 60 s (measure and write the number down).
  - Offline edit → reconnect → visible in web Contacts.
  - Concurrent web edit to a different field merges; to the same field, local wins and the conflict is logged.

**WS-25 App shell v2** (wave 2 end, M). Goal: every engine starts, and the navigation model knows contacts, outbox and virtual mailboxes.
- `AccountEngine` (`NextcloudMail/App/AccountEngine.swift`):
  - starts `OutboxSender` per mail account;
  - starts `ContactsSync`, `CalendarListSync` and `ServerResultFetcher` once per `AccountSession`;
  - `SettingsCommands` is created on demand (ADR-0053 pattern).
- `NavigationState` gains `enum SidebarSelection: Hashable, Codable` with cases:
  - `.mailbox(Int64)`, `.unifiedInbox`, `.priorityInbox`, `.favorites(inboxId: Int64)`, `.outbox`;
  - `.contacts(sessionId: String, scope: ContactsScope)`, where `ContactsScope` is `.all | .favorites | .addressBook(Int64) | .group(String) | .team(String) | .recent`.
- Add `ComposeRequest`, verbatim:

  ```swift
  enum ComposeRequest: Codable, Hashable, Sendable {
      case new(accountId: Int64?, mailto: URL?)
      case reply(messageId: Int64, mode: ReplyMode)          // ReplyMode: .sender, .all, .followUp
      case forward(messageIds: [Int64], asAttachment: Bool)
      case editAsNew(messageId: Int64)
      case draft(draftId: Int64)
      case outbox(outboxId: Int64)
      case smartReply(messageId: Int64, text: String)
      case shared(inboxItemId: String)                        // Share extension hand-off
  }
  ```

- Add an environment action `openComposer(_ request: ComposeRequest)` that calls `openWindow(id: "composer", value: request)`.
- Start-mailbox restore: the `start-mailbox-id` preference, saved after 5 s in a mailbox.
- Acceptance: every engine starts and stops with sign-in and sign-out, including contacts; selection restores across relaunch.

**WS-26 People** (wave 3, M). Goal: ADR-0072, plus the contact card used everywhere a person appears.
- Build in `NextcloudMail/Views/People/`:
  - `RecipientSuggestionProvider` (local query, then `ServerResultFetcher` supplement; also implements WS-20's `MentionProvider`);
  - `ContactCardPopover(email:)` for §5.11: contact match, Reply, Add to contact (search, then queue `contactPut`), New contact, Copy address;
  - `RecentMailList(email:)` for the contact detail pane.
- Acceptance: autocomplete is under 50 ms on 10,000 contacts offline (measure); "Add to contact" offline appears in web Contacts after reconnect.

**WS-27 Composer and outbox view** (wave 3, XL). Goal: §6 parity in a native compose window.
- `ComposerScene`: `WindowGroup(id: "composer", for: ComposeRequest.self)`. One window per draft; web "minimise" maps to window minimise; closing saves and closes the draft.
- Fields: From (accounts + aliases), To/Cc/Bcc chip fields with `RecipientSuggestionProvider` (built on NextcloudUI `NCUserPicker`/`NCChip` where they fit; gaps go to library feedback), Subject, `RichTextEditor`, attachments strip (upload, Files via WS-33, share link, drag and drop, paste).
- Reply and forward rules from §6.1, including localized prefix de-duplication (AW:, SV:, WG:, TR:, 回复:).
- Signature and quote placement from §6.6. `mailto:` parsing (`ComposeRequest.new(mailto:)`).
- Warnings: no subject, forgotten attachment, empty To, noreply.
- "…" menu: Smart Picker, text blocks, send later presets (09:00 / 14:00 / Monday 09:00 / custom), read receipt, mark as AI generated, S/MIME sign/encrypt.
- Undo-send banner in the main window. Quit with unsaved composers asks to save.
- Outbox view (`Views/Outbox/`) for §4.9.
- Acceptance: every §6 row except Mailvelope, demonstrated live; offline compose and send.

**WS-28 Sidebar and mailbox management** (wave 3, L). Goal: §3 parity.
- Virtual entries: Priority inbox, All inboxes (> 1 account), Favorites under each inbox, Outbox (when non-empty).
- Account menu: quota, show only subscribed, add folder, move up/down, remove account (via `SettingsCommands.deleteAccount`), delegate.
- Folder menu: every item in §3.3 through the queue kinds. Repair goes through the command, with 429 handled.
- Drop targets for drag and drop. Provisioned/disabled account row.
- The Contacts section slot (exception 1 in Step 4) stays empty until WS-35 adds it.
- Acceptance: every §3 row live; folder create/rename offline → appears after reconnect.

**WS-29 Message list parity** (wave 3, L). Goal: §2.4 and §4.1–§4.5 parity.
- Layouts: vertical split (current), horizontal split, list. Compact mode. Sort order written to the server preference.
- Favorites section; Priority sections (Favorites / Follow up / Important / Other); date groups Last hour → years.
- Row adornments: tags, attachment chips, AI summary preview, draft prefix.
- Hover quick actions; multi-select bulk header; `⌘A`; drag source; "Open in New Window".
- Acceptance: every listed row live; layout switching keeps selection.

**WS-30 Message view parity** (wave 3, XL). Goal: §5 parity except calendar (WS-34) and bubbles (WS-26).
- Thread mode with expandable messages; smart replies and thread summary through `serverResult`.
- Follow-up banner, unsubscribe (one-click / URL / mailto), MDN banner, phishing warning from `phishingJSON`, S/MIME status, translation banner and modal.
- PGP notice ("This message is encrypted with PGP and can't be read in this app."), "Contains AI content" badge, trust domain.
- View source, download `.eml`, save message or attachment to Files (WS-33 picker), zip download, Quick Look attachment preview, copy direct link, whole-thread print.
- Walk security checkpoint 2 for every WebView change.
- Acceptance: every listed §5 row live.

**WS-31 Triage parity** (wave 3, L). Goal: §4.4/§4.5 actions, §4.7, §4.8 and §2.6.
- Tag modal (set, unset, create, edit, delete).
- Snooze presets exactly as in §4.4 (Later today 18:00 before 17:00; Tomorrow 08:00; This weekend Mon–Thu; Next week except Sunday; custom), creating the Snoozed folder on first use. Unsnooze.
- Quick actions execution (respecting ACLs). Mark spam/not spam semantics.
- Forward N as attachment → `openComposer`. Edit as new. Move picker with breadcrumbs and search.
- Shortcuts: add `C` and `⌘N` compose, `⌘⇧D` send, `⌘S` save draft (composer), and the §2.6 table; all registered as menu items (ADR-0049).
- Acceptance: every action offline and undoable where the web is.

**WS-32 Search parity** (wave 3, M). Goal: §4.6 on the local index.
- Chips: Has attachment, Unread, To me.
- "Search parameters" sheet: subject, body, date range, from (max 1), to, cc, bcc, tags, important, favorite, attachments, mentions me. Terms need ≥ 2 characters.
- Acceptance: each filter has a query test; results stay instant offline.

**WS-33 Files picker and Files actions** (wave 3, M). Goal: everything that touches Nextcloud Files.
- `FilesListingSync` in `NCMailSync/Files/` (PROPFIND listings into `filesListing` per ADR-0067).
- `FilesPicker` sheet: browse, breadcrumbs, filter by type, multi-select; "Choose a folder" mode.
- Actions: attach file, insert image (≤ 10 MB, png/jpeg/gif/bmp/webp), add as share link (files_sharing OCS), save attachment / all attachments / message to Files.
- Acceptance: each action live; the picker shows the cached listing offline with an offline note.

**WS-34 Calendar integration** (wave 4, L). Goal: §5.9 parity.
- iMIP card: REQUEST/REPLY/CANCEL states; accept/decline/tentative with comment and "Save to" calendar, written via `calendarPut` (the server's scheduling sends the reply — confirm on the live server).
- Reply-with-meeting sheet (AI title and description via eventdata).
- Create task (VTODO calendars). Itinerary cards with import, de-duplicated by UID. `.ics` attachment import. The `imipCreate` setting UI lives in WS-39.
- Acceptance: accept an invite and the organiser receives the reply (live).

**WS-35 Contacts browse, view, edit** (wave 4, XL). Goal: ADR-0070 and the core of Contacts parity.
- `ContactsSidebarSection` (exception 1).
- Contact list: favorites first, sort per the Contacts setting, search via `contactSearch`, multi-select hand-off to WS-36.
- Detail pane headed by NextcloudUI `NCProfileCard`, with view and edit modes for every typed `VCard` property, plus "other properties" preserved read-only.
- Photo: upload, crop, remove, full size, download, social fetch. Groups (CATEGORIES). Favorites (the Contacts app's favourite marker — confirm which vCard property it uses before writing).
- New and delete contact. "New message" and `RecentMailList` from WS-26.
- Read-only address books disable editing with a reason.
- Acceptance: every WS-35 contacts row live, offline included.

**WS-36 Address books, import/export, merge, batch** (wave 4, L). Goal: the remaining Contacts parity rows.
- Address book management sheet: create, rename, enable/disable, share with user or group (read-only toggle), export `.vcf`, delete, copy CardDAV URL.
- vCard import (3.0/4.0, choose the target book).
- Merge two contacts (radio for single-value properties, checkboxes for multi-value; groups union by default).
- Batch delete. Contacts settings: sort order and social auto-update.
- Acceptance: import a 500-contact file offline, then reconnect and they all sync.

**WS-37 Teams, shared items, org chart** (wave 4, M). Goal: the Contacts rows gated on server apps.
- Teams list and detail via Circles OCS (unverified routes — confirm), cached per ADR-0067.
- Create team, add members (users, groups, emails, teams), roles, options. Hidden when Circles is absent.
- Shared items for system-address-book contacts. Organisation chart from ORG/RELATED manager properties.
- Acceptance: on a server without Circles nothing shows; with it, create a team and see it in the web client.

**WS-38 App settings parity** (wave 4, L). Goal: §7 parity in the Settings scene.
- Tabs: General ("Set as default mail app" button calling `NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")` directly, labelled "Default mail app" when `NSWorkspace.shared.urlForApplication(toOpen:)` for a `mailto:` URL built with `guard let` returns this bundle; accounts; add account → WS-40), Appearance, Messages, Privacy (data collection, trusted senders list), Security (highlight external, internal addresses, S/MIME certificate manager), Assistance, Context Chat, Keyboard shortcuts, About.
- S/MIME PKCS#12 import converts locally with `SecPKCS12Import`, then `SecKeyCopyExternalRepresentation` to PEM, then `SettingsCommands.importSMIME`. The password never leaves the device.
- Text blocks manager with sharing, using `RichTextEditor`.
- Acceptance: every §7 row except Mailvelope live.

**WS-39 Account settings parity** (wave 4, XL). Goal: §8 parity in a per-account settings window.
- Sections: aliases, alias→certificate, writing mode, signature (`RichTextEditor`, the 2 MB and images warnings), default folders, trash retention, folder search, autoresponder, classification, quick actions editor (terminal-step rules from §8.7), calendar setting, filters editor (§8.6), mail server, Sieve server, Sieve script editor, delegation.
- Provisioned accounts hide what §9's "provisioned" row says.
- Acceptance: every §8 row live; a Sieve syntax error shows the server's message.

**WS-40 Mail account setup** (wave 4, L). Goal: §1 parity.
- Auto mode with the same button label sequence (ISPDB → MX → connectivity → auth → loading). Manual IMAP/SMTP with port/security coupling and SMTP mirroring until edited.
- Google/Microsoft via `POST /api/oauth/state`, then `ASWebAuthenticationSession` to the server's OAuth URL.
  - Contingency: if the session cannot observe completion, open the default browser and poll `GET /api/accounts/{id}/test` every 2 s for up to 10 min. Closing the flow deletes the temporary account.
- Every §1.5 error string. Hidden when `allow-new-accounts` is off.
- Acceptance: add an IMAP account and a Gmail account (live).

**WS-41 Notifications, dock badge, Nextcloud notifications** (wave 5, M). Goal: §2.3 and the Notifications-app rows, natively.
- `MailNotifier` observes new inbox rows inserted by sync after the account's initial mirror is complete (no notification storm on first sync).
- Content: sender and subject (the content preview follows the system "Show previews" setting); grouped per thread; actions Archive, Mark read, Reply.
- Suppressed while the main window is key and showing that mailbox.
- Dock badge = unread count over every account's inbox.
- Nextcloud notifications OCS poll every 5 min for `app == "mail"` (quota, delegation) → native notifications.
- Acceptance: a mail sent from the web client notifies within one sync cycle; Archive from the notification works offline.

**WS-42 System integration** (wave 5, L). Goal: native equivalents of §10 web integrations.
- Incoming URLs: handle `mailto:` → `openComposer(.new(mailto:))` and the `ncmail://open/<Message-ID>` scheme (register both in Info.plist). Setting the default mail app is WS-38's button; this workstream only receives the URLs.
- Spotlight: `CSSearchableIndex` for messages and contacts, updated from store observations; opening a result selects the message or contact.
- WidgetKit extension target with Important and Unread widgets (ADR-0071).
- Share extension target: files/URLs → app-group inbox → `ComposeRequest.shared`.
- Services menu: "New Nextcloud Mail message with selection".
- App group entitlement. All project edits are owned here.
- Acceptance: each integration demonstrated on a clean user account.

**WS-43 Feedback v2** (∞, S). Same job as WS-15 for v2 (curate `library-feedback.md`, `server-findings.md` and `upstream-issues.md`); additionally the `NCRichContenteditable` proposal from WS-20.

**WS-44 Parity audit** (end, M). Goal: walk every row of `docs/product/parity.md` on a live server, including the `v1` rows. Set each to `Done` (with evidence) or reopen it as a named defect in the PR body against the owning WS. M16 exits when no row is `Planned`.

### Step 6 — Product overview, docs map, AGENTS.md, definition of done

**`docs/product/overview.md`:**
- Change the first line to `*What this app is, who it is for, and what v2 adds.*`.
- Change the one-sentence version to: "A native macOS mail and contacts client for Nextcloud that keeps a complete local copy of your mail and address books, so everything is instant and works with the network off."
- Under "Who it is for", replace the v1 "not … composes long HTML mail" paragraph with one saying v2 serves the person who writes mail too.
- Rename "What v1 does" to "What v1 shipped" (body unchanged).
- Replace "What v1 does not do" with "What v2 adds": one paragraph each for Compose, Mail parity, Contacts, Calendar from mail, Configuration, and On the Mac, each linking to `parity.md`. Then "What v2 does not do", listing ADR-0064's exclusions.
- Keep "What the mirror unlocks later" and add "contacts are the same mirror, the same queue".

**`docs/README.md`:**
- Product table: add a row for `product/parity.md`.
- Delivery table: roadmap becomes "Milestones M0–M16"; workstreams becomes "v1's 16 and v2's 29 workstreams".
- Replace "Fifteen records, ADR-0001 to ADR-0015." with "Records from ADR-0001 on; the index lists their status."
- Add `reference/server-flags.md` to the Reference table with "Written by WS-16".

**`AGENTS.md`:**
- Replace the sentence "WS-00 landed the skeleton … but no product code yet." with "v1 (WS-00–WS-15) has shipped: read and triage over a full local mirror."
- Replace "Work is divided into sixteen workstreams." with "v2 (WS-16–WS-44) is parity with the Nextcloud Mail web client plus Contacts; see `docs/delivery/roadmap.md`."

**`docs/delivery/definition-of-done.md`, `## Documentation`:** append
`- [ ] v2: every row of docs/product/parity.md that the brief owns is Done with evidence, or Excluded with an ADR.`

## Critical files & anchors

- `docs/delivery/workstreams.md`: the v1 graph, table and ownership table (lines ~14–98). v2 sections are added beside them, not replacing them.
- `docs/decisions/README.md`: index table ending at row 0063 (line ~78). Append 0064–0072 and change the 0012 row.
- `docs/delivery/briefs/WS-10-triage.md`: the tone and section template to copy for every v2 brief.
- `plan/API.md`: the authoritative route list WS-16's brief enumerates. The Admin settings section (line ~287) is excluded.
- `NextcloudMail/WebView/HTMLScanner.swift`: `HTMLScanner.tokens(of:)` and `HTMLEntities`, named in ADR-0065 and the WS-20 brief as the importer's tokenizer.

## Verification

Run from `/Users/hamzamahjoubi/Documents/nc/nc-mac-mail`.

1. `make lint-reuse` passes, which proves every new file has its SPDX header.
2. Every relative Markdown link in `docs/` and `AGENTS.md` resolves. Throwaway check:
   `python3 -c "import re,pathlib,sys;bad=[(p,l) for p in [*pathlib.Path('docs').rglob('*.md'),pathlib.Path('AGENTS.md')] for l in re.findall(r'\]\(([^)#:]+)(?:#[^)]*)?\)',p.read_text()) if not (p.parent/l).resolve().exists()];print(*bad,sep='\n');sys.exit(bool(bad))"`
   Expected: no output, exit 0.
3. Briefs complete: `ls docs/delivery/briefs/WS-{16..44}-*.md | wc -l` prints `29`. Each brief contains the seven headings `## Goal`, `## Before you start`, `## You own`, `## Build`, `## Acceptance`, `## Out of scope`, `## Report` (grep each file for all seven).
4. Parity coverage: every `###` subsection number in the issue (1.1–1.5, 2.1–2.7, 3.1–3.4, 4.1–4.9, 5.1–5.12, 6.1–6.9, 7.1–7.2, 8.1–8.8), plus §7, §8, §9, §10 and the appendix, appears in the Mail table of `docs/product/parity.md`. Check by grepping each identifier.
5. Ownership has no overlaps: every `Owns` path in the v2 table appears exactly once, apart from the documented `except` carve-outs. Review by reading the table.
6. Status edits: ADR-0012's status line reads `Superseded by ADR-0064`, and `docs/decisions/README.md` lists 0064–0072.

## Assumptions & contingencies

- **Admin settings (§9) and PGP are excluded** because the user left them unticked. PGP mail gets a notice in WS-30. If the user later wants either, write a new ADR superseding the relevant part of 0064 and add a workstream; nothing else in this plan changes.
- **Teams are included but capability-gated** (WS-37), because Nextcloud's own Contacts app manages Teams only when the Teams app UI is disabled. On servers without Circles, WS-37's surfaces never appear.
- **Routes marked unverified** (translation, Smart Picker, notifications, share links, Circles, the Contacts social-avatar route, the favourite marker) are confirmed by their owning workstream against the live server before use. If a route does not exist, that row moves to `Excluded` with a server-findings entry, not a workaround.
- **ADR statuses:** user-decided records are Accepted; roadmap-proposed records are Proposed until their owning workstream confirms them.
