<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0086: A provisioned account whose connection test fails is the sidebar's disabled row

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-28

## Context

The web client disables a provisioned account in its navigation — folders hidden, the menu
reduced to "Provisioned account is disabled" — when `provisioningId` is set, the page's
initial state says `password-is-unavailable` (the session logged in without a password, e.g.
SSO or WebAuthn) and a master password is configured (`Navigation.vue`, `isDisabled`). Loading
such an account's folders would fail and spin forever.

Neither `password-is-unavailable` nor the master-password flag reaches a native client: both
are server-rendered initial state of the web page, not part of any API the app calls. What
the app can observe is the effect — the server cannot open IMAP for that account —
through `GET /api/accounts/{id}/test`, which `SettingsCommands.testConnection` runs and
records as a `serverResult` row (`accountTest`, `{"ok": Bool}`).

## Decision

The sidebar runs the connection test once per account per launch, as the web client does at
load. Then:

- **Provisioned** (`account.provisioningId != nil`) and the test says `ok: false` → the
  disabled row: no folders, "Provisioned account is disabled", and the web's explanation in
  the account menu.
- **Not provisioned** and `ok: false` → the web's "Connection failed" row with "Change
  password", folders still listed (they are the mirror, readable offline).
- No result yet, or `ok: true` → the normal account.

## Consequences

- A provisioned account the server cannot connect for *another* reason (IMAP host down) also
  shows as disabled. For a provisioned account that is still the right answer: its
  credentials and hosts are the administrator's, so there is nothing for the user to change,
  and "Change password" would point at a form the account does not have.
- The decision is only as fresh as the last test; it is re-run on the next launch.

## Alternatives considered

**Ask the server for the flags.** No endpoint returns them; adding one is a server change.

**Never disable; show "Connection failed" for every account.** Offers a "Change password"
that a provisioned account cannot use.

## Revisit when

The Mail API exposes `password-is-unavailable` or the provisioning state of a session.
