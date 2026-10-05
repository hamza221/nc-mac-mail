<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Roadmap

*Seventeen milestones. Each one ends with something demonstrable — not "the store layer is
done" but "here, watch this".*

## v1 — shipped (M0–M7)

| M | Milestone | Workstreams | Demonstrable |
| --- | --- | --- | --- |
| **M0** | It builds | WS-00 | `xcodebuild -scheme NextcloudMail build` is clean with warnings as errors; `swift test` passes in every package; CI is green on a pull request |
| **M1** | It signs in | WS-01, WS-02, WS-13 | Launch, enter a server, authenticate in the browser, and the app prints the account list and wears the instance's brand colour |
| **M2** | It remembers | WS-03, WS-14 | The schema migrates from empty, round-trips every recorded fixture, and a migration test asserts it matches `schema.sql`. The fake transport can replay a session |
| **M3** | It mirrors | WS-04 | Sign in on a real account and watch the mirror fill. Quit mid-backfill, relaunch, watch it resume. Pull the cable, watch it pause |
| **M4** | It reads | WS-07, WS-08, WS-09 | Sidebar, list and message, all from the database. Turn the wifi off and keep reading |
| **M5** | It triages | WS-05, WS-06, WS-10 | Archive with `A` and see it in the web client. Do it offline, quit, relaunch, reconnect, see it arrive |
| **M6** | It finds things | WS-11, WS-12 | Type three letters, get results from 40,000 messages instantly, offline. Settings shows the size and can purge it |
| **M7** | It is honest | WS-15 | `docs/feedback/library-feedback.md` has the evidence `NextcloudUI` needs to freeze its API, and the server findings are written up for upstream |

## v2 — parity (M8–M16)

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

## Order, and what it buys

M8–M9 are foundations and engines with nothing visible, exactly as M1–M3 were. WS-20 (the
editor) starts in wave 1 because it depends on nothing and is the longest single item.
Contacts sync (WS-24) lands in M9 so that composer autocomplete (M10) is local from day
one.

## Parallelism

Wave 1 has five agents. Wave 2 has four, then WS-25 integrates them. Wave 3 has up to
eight. The dependency graph in [workstreams.md](workstreams.md) remains the authority.

## What is not on this roadmap

Admin settings, PGP, and debug-only tools
([ADR-0064](../decisions/0064-v2-parity-scope.md)).

Release engineering — Developer ID signing, notarization, a DMG, Sparkle updates — is
deferred until there is something to release, matching the library's own decision. WS-00
leaves the hooks: hardened runtime on, entitlements minimal, no private API.
