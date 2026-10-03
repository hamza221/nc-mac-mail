<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-37 — Teams, shared items, org chart

**Wave 4, after WS-35. Size: M.**

## Goal

The Contacts rows gated on server apps: Teams, shared items, and the organisation chart.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your rows in [../../product/parity.md](../../product/parity.md) — the Contacts table
- [../../decisions/0067-server-results-are-rows.md](../../decisions/0067-server-results-are-rows.md)
  — Teams lists are cached rows

## You own

`NextcloudMail/Views/Contacts/Teams/**`

## Build

Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
build, so reviewers check against a written spec.

- **Teams list and detail** via Circles OCS (unverified routes — confirm), cached per
  [ADR-0067](../../decisions/0067-server-results-are-rows.md).
- **Create team**, add members (users, groups, emails, teams), roles, options. **Hidden when
  Circles is absent.**
- **Shared items** for system-address-book contacts.
- **Organisation chart** from ORG/RELATED manager properties.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- On a server without Circles nothing shows; with it, create a team and see it in the web
  client.

## Out of scope

Contact browsing and editing (WS-35). Address books and batch operations (WS-36). The
contacts mirror (WS-24). The Circles endpoints themselves (WS-16 confirms and records
unverified routes).

## Report

Additionally: the confirmed Circles OCS routes (and where you recorded them), and how the
app detects that Circles is absent.
