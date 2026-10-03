<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Testing strategy

*What we test, where, and why the fixtures come from a real server.*

## The shape

```
                     slow, few
                         ▲
              ┌──────────┴──────────┐
              │  manual, live server │   the checklist in each brief
              ├─────────────────────┤
              │  integration        │   real GRDB + fake transport
              ├─────────────────────┤
              │  decoding           │   recorded fixtures
              ├─────────────────────┤
              │  unit               │   pure logic, no I/O
              └─────────────────────┘
                         ▼
                     fast, many
```

Framework: **Swift Testing** (`@Test`, `#expect`). XCTest only where an Apple API demands
it.

## Unit — pure logic

No database, no network, no clock. These are the tests that stay useful for years:

- `MailboxTree`: flat list to tree, delimiter handling, special-role ordering, a mailbox
  named `INBOX.a.b.c` with no parent rows, `\noselect` containers, an empty delimiter.
- Thread grouping: newest per thread, counts, unread counts, a thread whose head was
  deleted.
- Cursor arithmetic: duplicate `dateInt` at a page boundary, a short page, an empty page.
- HTML rewriting: `data-original-src` restoration, `srcset`, `url()` in inline styles,
  `cid:` mapping, and a hostile document that tries to escape the rewrite.
- Operation collapsing: flag-then-flag, move-then-move, anything-then-delete, and the
  cases that must **not** collapse.
- Filter and query building.
- `NCUsernameColor` parity is the library's test, not ours — do not duplicate it.

## Decoding — against recorded fixtures

**Every fixture is a real server response, recorded, never hand-written.** A fixture
someone typed tests that the decoder matches that person's idea of the payload, which is
the thing most likely to be wrong.

```sh
Scripts/record-fixtures.sh https://cloud.example.com user 'app-password'
```

Writes, with addresses and tokens scrubbed, to
`Packages/NCMailTestSupport/Sources/NCMailFixtures/Resources/Fixtures/` — a test-only
package, because a SwiftPM test target cannot reference files outside its own package.
`NCMailFixtures` is a dependency-free target inside that package, so `NCMailCore`'s,
`NCMailNet`'s and `NCMailStore`'s own test targets can all load fixtures through
`Bundle.module` without a package cycle back through `NCMailTestSupport` itself
([ADR-0026](../decisions/0026-fixtures-through-a-dependency-free-target.md)). Names below
are what the recorder actually writes, not an aspirational list — a name that lied about
what the server sent (`error-mailbox-not-found.json` for an endpoint that answers 403, not
404) got renamed rather than left to mislead the next reader:

```
accounts.json                    mailboxes-account.json
messages-inbox-page1.json        messages-inbox-page2.json
message-body.json                message-body-attachments.json
message-html-plain.html          message-thread.json
sync-initial.json                sync-incremental.json
capabilities.json                mailbox-stats.json
preference-sort-order.json       trustedsenders.json
error-mailbox-forbidden.json     error-message-forbidden.json
avatar-404.txt
```

A test per fixture asserts the model decodes and that the fields we depend on are present.
When the server changes shape, the build fails with a decoding error naming the endpoint —
which is the whole point, and why `MailError.decoding` carries the endpoint name.

Scrubbing is part of the recorder, not a manual step: addresses become `user1@example.com`,
subjects and preview text are kept (they are the interesting part for decoding) unless
`--scrub-content` is passed, and every token, hmac and URL credential is replaced.

**Known gap: no envelope carries an avatar.** Nextcloud resolves avatars asynchronously and
caches them; the recording ran against a cold cache, so `avatar` is `null` on all 95
recorded envelopes. Warming the cache first — fetching `/api/avatars/image/{sender}` for a
few senders before recording — would give a populated fixture, but it also makes the
Nextcloud server fetch each sender's favicon or Gravatar from their domain, which tells that
domain who the account owner corresponds with, every time anyone runs the recorder. Not
worth it for a URL field. `ModelDecodingTests` in `NCMailCoreTests` asserts the null path
unconditionally and checks the populated shape only if a future recording happens to have
one — an honest gap, not a flaky assertion waiting for cache luck.

**Also missing:** `error-mailbox-not-cached.json` (a 428 mid-warm) and `error-sync-202.json`
(a sync still in progress) are not yet recorded. The live account's mailboxes cache fast
enough that catching either requires racing the request against the server, which the
recorder does not attempt yet — left for whichever workstream first needs them.

## Store — real GRDB, in memory

- Migrate from empty; assert the result equals
  [../reference/schema.sql](../reference/schema.sql) by diffing `sqlite_master`. This test
  is why the schema file is the contract and not a comment.
- Migrate from v1 to v2 with data present, when there is a v2.
- Every query that the UI depends on, including the windowed list query and the threaded
  grouping, on a seeded database of 50,000 rows with an assertion on **query plan**, not
  just result — an index that silently stops being used is the classic way a list gets slow.
- FTS: insert, update, delete, diacritics, prefix, ranking, and the invariant that no row
  exists in `message` without its `messageSearch` counterpart.
- Cascades: deleting an account removes everything under it and leaves nothing orphaned.

## Sync and queue — fake transport

`FakeTransport` (WS-14) replays fixtures, and can be told to fail, stall, return 429, or
return a specific status per endpoint. It is what makes the hard cases testable at all:

- backfill: resume after a crash mid-page; resume after a quit mid-body-pass; a mailbox
  that 428s then succeeds; a 202 that resolves on the third try;
- sync: vanished handling, thread siblings that `newMessages` omits, a mailbox re-created
  server-side with new ids, deep reconcile finding a hole;
- queue: every case listed in
  [../architecture/offline-queue.md](../architecture/offline-queue.md#testing-it);
- ordering: a sync arriving mid-drain must not overwrite a pending intent;
- cancellation: a stalled request, then a cancel, must not leave a half-written transaction.

Rules: no `sleep` — the fake transport hands back a continuation the test resumes; no real
clock — time is injected; every test builds its own in-memory database.

## Manual, against a live instance

Some things only a real server tells you. Each brief carries the subset that applies to it;
the full list:

1. `Scripts/smoke-auth.sh` returns the account list as JSON (**WS-01, before any Swift**).
2. Sign in, and the app password appears in the user's security settings as
   **Nextcloud Mail (macOS)**.
3. Backfill a real account; record wall-clock time, request count, and final database size,
   and replace the estimates in
   [../architecture/local-mirror.md](../architecture/local-mirror.md#sizing-so-nobody-is-surprised).
4. Quit mid-backfill, relaunch: it resumes.
5. Airplane mode: read, search, triage. Reconnect: the queue drains.
6. Act in the web client; the change appears here within the sync interval.
7. Act here; the change appears in the web client.
8. Open a message with remote images: nothing loads until **Show images**; the sender's
   trust setting then matches the web client.
9. A message with inline images: they render, and still render offline.
10. Change the instance's theme colour; relaunch; the app recolours.
11. Run from Xcode and confirm sidebar icons are MDI glyphs, not SF Symbols
    ([ADR-0001](../decisions/0001-xcode-project-in-git.md)) — and confirm it again in a
    signed Release build, which nobody has checked.

## CI

| Trigger | Runs |
| --- | --- |
| Every push | `swift build` + `swift test` in every package, warnings as errors |
| Every push | `swift-format --lint`, `swiftlint --strict` |
| Every pull request | `xcodebuild -scheme NextcloudMail build` on a macOS runner with Xcode 26 |
| Every pull request | Thread Sanitizer on the package test targets |
| Nightly | The full suite plus a fake-transport backfill of a 50,000-message synthetic account, asserting time and peak memory |

No CI job touches a real Nextcloud server. Fixtures are recorded by a person and committed.
