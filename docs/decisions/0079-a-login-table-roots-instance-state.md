<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0079: A `login` table is the local identity for instance-scoped state, and sign-out is two cascade roots

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-18, while designing the v2 schema's delete-login cascade

## Context

v2 stores state that belongs to a Nextcloud *login* rather than to a mail account: address
books and contacts arrive over CardDAV and one login has one set of them however many mail
accounts it has (ADR-0069); preferences are per user; cached server results, Files
listings, teams and calendars are all instance-scoped. v1 has no row for a login — the
identity lives inline on `account` as `(serverURL, loginName)` (ADR-0033), and a login with
no mail account yet has no row anywhere.

The acceptance bar is WS-03's, one level up: **deleting a Nextcloud login leaves no orphans
in any table, including contacts and FTS.** ADR-0024 already established that deletes must
live in the schema, because not every delete goes through Swift.

Separately, WS-16 measured that the appendix flags (`allow-new-accounts`,
`disable-snooze`, `attachment-size-limit`, the `llm_*` family, the OAuth URLs, …) are
instance-wide server configuration, not account fields — the brief's "account columns for
… the flags discovered by WS-16" had the scope wrong, and reality wins.

## Decision

v2 adds a `login` table: one row per `(serverURL, loginName)`, the same pair the Keychain
item and `AccountSession` are keyed by. Everything instance-scoped references it with
`ON DELETE CASCADE`: `preference`, `textBlock` (and its shares), `trustedSender`,
`internalAddress`, `smimeCertificate`, `serverResult`, `recipientSuggestion`,
`filesListing`, `smartPickerResult`, `addressBook` (and under it the whole contacts
mirror), `calendar` and `team`.

The appendix flags become nullable columns on `login`, not on `account`. NULL means "not
discovered yet", and the UI treats the feature as available until a sync writes otherwise —
the contingency WS-16's brief prescribes, as a representable state instead of a convention.

`account` does **not** gain a `loginId`. Its rows carry the identity inline since v1, every
mail-side cascade already hangs off it, and retrofitting a foreign key would mean either a
nullable column that cannot cascade or a rebuild of the most-referenced table in the file.
Sign-out is therefore `MailStore.deleteLogin(_:)`: two DELETEs — the identity's `account`
rows, then its `login` row — in one transaction. The FTS triggers (`messageSearchDelete`,
and v2's `contactSearchDelete` per ADR-0024) take the index rows with them.

The v2 migration backfills `login` from the accounts already mirrored, so a database
upgraded mid-life has a row per signed-in identity before any v2 sync runs; `ensureLogin`
covers a login signed in later, before its first account row lands.

`LoginCascadeTests.deletingALoginLeavesNothingBehind` seeds every table in the schema and
counts them all after `deleteLogin`; `deletingOneLoginLeavesTheOtherWhole` is the
two-instance counterpart.

## Consequences

- One DAO call signs a login out of the mirror completely, and the completeness is in the
  schema, not in a list of tables some Swift function has to remember.
- Instance-scoped rows are written against a `loginId`, so sync code must call
  `ensureLogin` before its first instance-scoped write. That is one extra call per sync
  run, and it is idempotent.
- The identity now exists in two shapes: inline on `account` (v1, unchanged) and as a
  `login` row. They cannot drift — both are written from the same `ServerIdentity` — but a
  reader has to know which tables key off which, and `schema.sql` says so per table.
- The flag columns live where the data does, so "is snooze disabled on this server" is one
  indexed lookup on a row the sidebar already observes.

## Alternatives considered

**Key instance state by `(serverURL, loginName)` columns on every table.** No new table,
but no cascade root either: sign-out becomes N DELETEs that every future instance-scoped
table has to join, which is exactly the "rule four other agents have to remember" ADR-0024
exists to prevent.

**Give `account` a `loginId` and make `login` the single root.** The cleanest-looking
shape, and the costliest: ALTER TABLE cannot add a NOT NULL foreign key, so either the
column is nullable and rows with NULL silently escape the cascade, or `account` — referenced
by `mailbox`, `message`, `tag`, `pendingOperation` and five v2 tables — is rebuilt
table-copy style inside a migration. Two DELETEs in one transaction buy the same guarantee
for none of that risk.

**Flags as `meta` keys or a `preference` row.** Loses the types, the per-login scope and
the single-row observation; ADR-0067 already rejected the generic key-value shape for
server state.

## Revisit when

A second consumer needs `account` joined to `login` (not just scoped deletes), at which
point a `loginId` on `account` earns its migration; or the server starts exposing the
appendix flags per account, at which point they move where the server puts them.
