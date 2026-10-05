<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-38 — App settings parity

**Wave 4, after WS-20, WS-21 and WS-22. Size: L.**

## Goal

§7 parity in the Settings scene.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — §7, 7.1, 7.2, Context Chat
- [../../decisions/0068-settings-commands.md](../../decisions/0068-settings-commands.md)
  — server-validated settings are commands

## You own

`NextcloudMail/Views/Settings/**` except `Account/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **Tabs**: General ("Set as default mail app" button calling
  `NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")`
  directly, labelled "Default mail app" when `NSWorkspace.shared.urlForApplication(toOpen:)`
  for a `mailto:` URL built with `guard let` returns this bundle; accounts; add account →
  WS-40), Appearance, Messages, Privacy (data collection, trusted senders list), Security
  (highlight external, internal addresses, S/MIME certificate manager), Assistance, Context
  Chat, Keyboard shortcuts, About.
- **S/MIME PKCS#12 import** converts locally with `SecPKCS12Import`, then
  `SecKeyCopyExternalRepresentation` to PEM, then `SettingsCommands.importSMIME`. **The
  password never leaves the device.**
- **Text blocks manager** with sharing, using `RichTextEditor`.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every §7 row except Mailvelope live.

## Out of scope

Account settings (WS-39). Mail account setup (WS-40). Default-mail-app URL handling — the
`mailto` handler itself (WS-42). The editor (WS-20); the commands actor (WS-22). Mailvelope
is excluded ([ADR-0064](../../decisions/0064-v2-parity-scope.md)).

## Report

Additionally: whether the default-mail-app detection via `urlForApplication(toOpen:)` was
reliable across relaunches, and anything `SecPKCS12Import` rejected that the web client
accepts.
