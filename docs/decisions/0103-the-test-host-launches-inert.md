<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0103: The test host launches inert

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** a deflake pass over `make test-app`, after a Keychain consent prompt per rebuild

## Context

The app target is the unit tests' host: every `xcodebuild test` launches `NextcloudMail.app`,
and `@main` runs before any suite does. That launch did what a user's launch does — opened the
mirror at `MailStore.defaultDatabaseURL()` and, once the window appeared, `AppSession.start()`
read every Keychain account. ADR-0054 moved those reads off the main thread, which fixed the
hang it documents; the reads themselves remained.

On a machine signed into real accounts, those reads hit real `kSecClassInternetPassword`
items. `SecItemCopyMatching` answers with a consent dialog whenever the item's ACL does not
match the running binary, and the project signs ad hoc (ADR-0018), so the signature changes on
every rebuild: each test invocation after a rebuild prompts for the login keychain password,
once per stored account. A deflake session of thirty targeted runs is thirty rounds of
prompts. Worse, when consent *is* granted, the host starts real engines that sync a real
account underneath the suites — network, CPU and main-actor contention no suite asked for, on
the same main actor whose contention the clock-bound waits already absorb.

## Decision

`NextcloudMailApp` detects a hosted test run — an `XCTest*` environment variable at launch, or
the `XCTestCase` class once the runner has injected the bundle — and launches inert:
`openStore()` returns a migrated in-memory mirror (deliberate, so not `mirrorIsTemporary`),
and the window's `.task` never calls `AppSession.start()`. The suites keep building their own
stores and sessions, exactly as they always have.

`TestHostTests` pins both halves from inside a hosted run: detection answers yes there, and
the store the launch opens has zero bytes on disk.

## Consequences

- No Keychain consent prompt during any test run, on any rebuild; nothing to click through.
- No engine runs against a developer's real account during tests; the host's window shows the
  sign-in screen over an empty in-memory mirror.
- The live suites that exercise the real Keychain on purpose still do
  (`SettingsStoreLiveTests`, behind `NCMAIL_KEYCHAIN_TESTS=1`); this stops only the implicit
  reads the host never needed.
- An integration test that wants the full launch path cannot get it by accident; it would
  have to go around `isHostingTests` explicitly, and should say why.
