<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0084: The shell starts a login's engines before its accounts', stops them in reverse, and restores the local selection before the server's start mailbox

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-25

## Context

Wave 2 added engines at two levels. Per Nextcloud login: `ContactsSync`, `CalendarListSync`,
`ServerResultFetcher`, `ServerStateMirror`, and the `ContactWriteHandler` every queue and
drainer of the login needs. Per mail account row: v1's `MirrorCoordinator`, `SyncScheduler`
(with its `OperationDrainer`), `AvatarFetcher`, and now `OutboxSender`. They depend on each
other across the levels: the scheduler takes the login's `ServerStateMirror` for its
deep-reconcile trigger, the outbox calls the same mirror's `refreshOutbox()`, and the
drainer sends contact writes through the login's handler. `ContactsSync` and
`CalendarListSync` take a local `loginId`, which only exists once the `login` row does.

Before WS-25, sign-out stopped nothing when the user chose to keep local copies, and a row
removed by "remove local copies" stopped only the account-level engines. The login-level ones
have no account row to lose.

Separately, v2 brings the web client's `start-mailbox-id` preference: the web saves the open
mailbox's server id 5 s after it is opened and opens on it at the next load. v1 already
restored the last selection from `meta`.

## Decision

1. **Logins first.** For each signed-in session the engine resolves (`ensureLogin`) the
   `login` row, builds the login's engines, starts them (calendars, contacts, results, server
   state — whose start is the `.launch` refresh), and only then starts the account rows of
   that login, waiting rows included. Discovery runs alongside, as before (ADR-0047).
2. **Stop in reverse.** Sign-out, a re-sign-in after a 401, and `stopAll()` stop every
   account of the session (outbox, avatars, scheduler, mirror), then the login (server state,
   results, contacts, calendars). A stop first waits for that part's start to finish, so a
   part is never started after it was stopped. Actors with no `stop()` of their own
   (`MirrorCoordinator`, `ServerStateMirror`, `ServerResultFetcher`) are stopped by telling
   them they are offline, which ends their work and every later trigger; a stopped instance
   is discarded and never told otherwise.
3. **Sign-out is the login's.** The Keychain item is per login, so signing out one account
   row signs out every account of that login. Settings tells `AppSession` once it has removed
   the item; the engine stops the session and forgets it, so its rows start nothing again
   this launch. With "remove local copies", the `login` row is deleted after the stop, which
   cascades to address books, contacts, calendars and the settings mirror.
4. **Engines are built by an `EngineFactory`** of closures; `AccountEngine` drives
   `EnginePart`s (`engineStart/Stop/Apply/Wake`). The live factory is the only code that
   names the concrete actors; tests pass recording fakes and a discovery that opens no socket.
5. **`SettingsCommands` is never running**: `settingsCommands(sessionId:)` builds one per use
   (ADR-0053's on-demand pattern).
6. **Restore order:** the selection this Mac saved (any `SidebarSelection`, JSON in `meta`
   under `navigation.selection`; v1's mailbox id is migrated once) wins; with none, the
   server's `start-mailbox-id` mapped to a local mailbox (or `unified` / `priority`); else
   nothing. A selection the user stays on for 5 s (mailbox, Unified, Priority) is queued as
   `setPreference(start-mailbox-id)` unless the login already holds that value; Unified and
   Priority go to every signed-in login.

## Consequences

- A login whose `login` row cannot be written starts no account either. That is a broken
  mirror, which already has its own recovery (`mirrorIsTemporary`).
- The `ServerStateMirror` launch refresh is not cancelled by a stop; a refresh in flight at
  sign-out finishes its current writes. Offline it never starts. Recorded in
  library-feedback as the missing `stop()`.
- A launch on a Mac that already has a saved selection ignores a start mailbox changed on the
  web since. That is the restoration [ux-spec.md](../product/ux-spec.md#window) asks for; the
  server value is what a new Mac or a wiped mirror opens on.
- `.favorites`, `.outbox` and `.contacts` restore locally but are never a start mailbox: the
  web client has no equivalent value.

## Alternatives considered

**Start login engines lazily from the first account row.** Rejected: contacts belong to the
login and must run even when a login's mail accounts are still being discovered, and two
triggers for one start are two ways for it to go wrong.

**Abstract every actor behind a protocol with all its methods.** Rejected as abstraction for
its own sake; the engine needs four lifecycle calls plus a handful of closures (select,
sync now, retry, wake drainer), which is what `AccountEngines` carries.

**Let the server's start mailbox win at launch, as the web does.** Rejected: on the Mac the
last place the user was is restored exactly (a contacts scope included), and the 5 s settle
means the two agree whenever the user stayed anywhere.

## Revisit when

`ServerStateMirror`, `MirrorCoordinator` or `ServerResultFetcher` gain a real `stop()` —
the `EnginePart` conformances switch to it and the offline stand-in goes.
