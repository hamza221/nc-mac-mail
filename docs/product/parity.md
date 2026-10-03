<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Parity matrix

*Every user-facing behaviour of the Nextcloud Mail web client and Nextcloud Contacts, mapped to the workstream that delivers it or the ADR that excludes it.*

The Mail rows come from the manual frontend QA checklist at
https://github.com/nextcloud/mail/issues/13797, opened 2026-10-02 against nextcloud/mail 5.12,
which walks every user-visible surface of the web client section by section. Each row below
names the checklist subsection, the workstream that owns it in v2 (per the roadmap), and how
the behaviour maps to a native macOS app. Rows marked `v1` already shipped and are verified at
the end by WS-44; rows marked `Excluded (ADR-0064)` are out of scope by decision record.

## Mail

| § | Area | Owner | Native mapping / note | Status |
| --- | --- | --- | --- | --- |
| 1.1–1.5 | Setup page, account form (Auto/Manual), OAuth, error feedback | WS-40 | Native setup window; Google/Microsoft OAuth through `ASWebAuthenticationSession` | Planned |
| 2.1 | Start-up and routes | WS-25 | Start mailbox restore; deep links become `ncmail://open/<Message-ID>` (WS-42); browser history → native window/selection restoration; Ctrl+click new tab → "Open in New Window" | Planned |
| 2.1 | Session expiry | v1 | 401 modal already exists | v1 |
| 2.2 | Background sync | v1 + WS-21 | Outbox refresh in WS-21; cadence is v1's | v1 |
| 2.3 | Desktop notifications | WS-41 | Notification Center; suppressed while the window is key (fixes the web ⚠) | Planned |
| 2.4 | Layout and appearance preferences | WS-29 (behaviour), WS-38 (settings UI) | Vertical, horizontal and list layouts; compact mode; sort order; favorites up | Planned |
| 2.5 | Responsive, dark mode, RTL | DoD | Responsive → native window resizing (excluded as browser mechanics); dark mode and RTL are definition-of-done gates; composer RTL in WS-20 | Planned |
| 2.6 | Keyboard shortcuts | WS-31 | Adds `C`/`⌘N` compose and `⌘⇧D` send; ⚠ unbound keys become bound | Planned |
| 2.7 | Accessibility | DoD | — | Planned |
| 3.1–3.3 | Left navigation structure, account menu, folder menu | WS-28 | — | Planned |
| 3.4 | Drag and drop envelopes → folders | WS-28 (drop targets), WS-29 (drag source) | — | Planned |
| 4.1 | States and grouping | WS-29 | — | Planned |
| 4.2 | Priority inbox and favorites | WS-28 (entries), WS-29 (sections) | Important/Other are local queries over `isImportant` | Planned |
| 4.3 | Envelope row | WS-29 | — | Planned |
| 4.4 | Envelope "…" menu | WS-29 (menu), WS-31 (actions) | — | Planned |
| 4.5 | Multi-select and bulk actions | WS-29, WS-31 | Native adds `⌘A` | Planned |
| 4.6 | Search | WS-32 | Local FTS; server body search unnecessary | Planned |
| 4.7 | Folder pickers | WS-31 | — | Planned |
| 4.8 | Tags | WS-31 | — | Planned |
| 4.9 | Outbox | WS-23 (engine), WS-27 (view) | — | Planned |
| 5.1–5.4 | Thread container, header content, action bar, message menu | WS-30 | — | Planned |
| 5.5 | Reply area, smart replies, follow-up | WS-30 | Prefill through WS-27 | Planned |
| 5.6 | Unsubscribe | WS-30 | — | Planned |
| 5.7 | Body rendering | WS-30 | PGP row → notice only (ADR-0064) | Planned |
| 5.8 | Translation modal | WS-30 | — | Planned |
| 5.9 | Calendar: iMIP, events, tasks, itineraries | WS-34 | — | Planned |
| 5.10 | Attachments | WS-30, WS-33 | Viewer → Quick Look | Planned |
| 5.11 | Recipient bubbles | WS-26 | — | Planned |
| 5.12 | Printing | v1 + WS-30 | Whole-thread print in WS-30 | v1 |
| 6.1, 6.3, 6.4, 6.6–6.9 | Composer: entry points, window, recipients, signature, attachments, actions, sending | WS-27 | Sending in WS-23; Files attachments and share links in WS-33 | Planned |
| 6.2 | mailto | WS-42 (handler), WS-27 (parser) | Default mail app via `NSWorkspace` | Planned |
| 6.5 | Editor | WS-20 | — | Planned |
| 6.8, 6.9 | Mailvelope rows | Excluded (ADR-0064) | — | Excluded (ADR-0064) |
| 7, 7.1, 7.2 | App settings dialog, text blocks, S/MIME certificates | WS-38 | PKCS#12 converted locally | Planned |
| 7 | Security Mailvelope card | Excluded (ADR-0064) | — | Excluded (ADR-0064) |
| 8, 8.1–8.8 | Account settings: aliases, S/MIME mapping, writing mode/signature/defaults, autoresponder, Sieve, filters, quick actions, delegation | WS-39 | — | Planned |
| 9 | Admin settings | Excluded (ADR-0064) | — | Excluded (ADR-0064) |
| 10 | App menu | — | Native: Dock; nothing to build | Planned |
| 10 | Dashboard widgets | WS-42 | WidgetKit | Planned |
| 10 | Unified search | WS-42 | Spotlight | Planned |
| 10 | Notifications app | WS-41 | Quota and delegation notices via the notifications OCS API | Planned |
| 10 | mailto handler, error template | WS-42, WS-30 | — | Planned |
| 10 | OCP Mail Provider, junk reports, user migration, AI listeners | Excluded (ADR-0064) | Server-only; their visible output is covered by WS-29 and WS-30 | Excluded (ADR-0064) |
| 10 | Contacts interaction, drafts cleanup | WS-23 | Verify the server does it on send | Planned |
| 10 | Context Chat | WS-38 | Preference toggle | Planned |
| 10 | Provisioning middleware | WS-28, WS-39 | Disabled provisioned accounts; locked sections | Planned |
| — | "Not present in the code" list | WS-29, WS-41 | Native adds select-all and a dock badge; the right-click menu and offline indicator are v1 | Planned |
| Appendix | Preferences and flags that gate UI | WS-16 | Records how each flag is discovered without the web page's initial state | Planned |

## Contacts

Source: https://docs.nextcloud.com/server/latest/user_manual/en/groupware/contacts.html plus the
Nextcloud Contacts app.

| § | Area | Owner | Native mapping / note | Status |
| --- | --- | --- | --- | --- |
| C1 | Add contact, edit, remove, every vCard field | WS-35 | — | Planned |
| C2 | Contact picture: upload, remove, full size, download, social-network fetch | WS-35 | — | Planned |
| C3 | Favorites | WS-35 | — | Planned |
| C4 | Contact groups | WS-35 | — | Planned |
| C5 | Multi-select batch delete | WS-36 | — | Planned |
| C6 | Merge two contacts | WS-36 | — | Planned |
| C7 | vCard import (3.0/4.0) | WS-36 | — | Planned |
| C8 | Address books: create, rename, enable/disable, share, export, delete, copy CardDAV URL | WS-36 | — | Planned |
| C9 | Contacts settings: sort order, social avatar auto-update | WS-36 | — | Planned |
| C10 | Teams: create, members, roles, options | WS-37 | Gated on the Circles app being present | Planned |
| C11 | Shared items | WS-37 | — | Planned |
| C12 | Organisation chart | WS-37 | — | Planned |
| C13 | Mail↔Contacts integration (autocomplete, sender cards, add to contact, recent mail with a contact, contact photos as avatars) | WS-26 and WS-24 | — | Planned |
