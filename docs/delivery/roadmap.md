<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Roadmap

*Eight milestones. Each one ends with something demonstrable — not "the store layer is
done" but "here, watch this".*

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

## Order, and what it buys

M1 to M3 are sequential and unglamorous: nothing is visible until M4, and then everything
is. That is the cost of the mirror, and it is why M3's demonstration is a progress bar
filling rather than a screenshot.

M4 is where the library gets tested for real, which is the second reason this project
exists. Do not let it slip behind M5.

## Parallelism

After M0, three agents work at once (WS-01, WS-02, WS-03). After M3, four (WS-07, WS-08,
WS-09, WS-13). The dependency graph in [workstreams.md](workstreams.md) is the authority;
the file-ownership table is what makes the parallelism safe.

## What is not on this roadmap

Compose, account setup, tags, snooze, priority inbox, unified inbox, S/MIME, PGP, itinerary
cards, AI features, Sieve. All deliberate
([ADR-0012](../decisions/0012-read-and-triage-scope.md)), all easier once the mirror
exists.

Release engineering — Developer ID signing, notarization, a DMG, Sparkle updates — is
deferred until there is something to release, matching the library's own decision. WS-00
leaves the hooks: hardened runtime on, entitlements minimal, no private API.
