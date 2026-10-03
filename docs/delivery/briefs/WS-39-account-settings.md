<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-39 — Account settings parity

**Wave 4, after WS-20, WS-21 and WS-22. Size: XL.**

## Goal

§8 parity in a per-account settings window.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — §8, 8.1–8.8, provisioning
- [../../decisions/0068-settings-commands.md](../../decisions/0068-settings-commands.md)
  — server-validated settings are commands

## You own

`NextcloudMail/Views/Settings/Account/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **Sections**: aliases, alias→certificate, writing mode, signature (`RichTextEditor`, the
  2 MB and images warnings), default folders, trash retention, folder search, autoresponder,
  classification, quick actions editor (terminal-step rules from §8.7), calendar setting,
  filters editor (§8.6), mail server, Sieve server, Sieve script editor, delegation.
- **Provisioned accounts hide what §9's "provisioned" row says.**
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every §8 row live; a Sieve syntax error shows the server's message.

## Out of scope

App-wide settings (WS-38). Mail account setup (WS-40). The editor (WS-20); the commands
actor and queue kinds (WS-22). The iMIP card UI that the calendar setting governs (WS-34).

## Report

Additionally: how the Sieve 422 message surfaced through `CommandOutcome`, and which
sections the provisioned row ended up hiding in practice.
