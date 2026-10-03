<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0064: v2 is parity with the Nextcloud Mail web client's user surfaces, plus Contacts

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** product owner, v2 planning

Supersedes ADR-0012.

## Context

ADR-0012 scoped v1 to read and triage, with no composer. v1 shipped that scope. The
question for v2 is what the app grows into, and the honest yardstick is the Nextcloud Mail
web client: nextcloud/mail#13797 enumerates its user surfaces as a checklist. Some of that
checklist is not a client surface at all, and some of it is browser machinery that a
native app replaces rather than reproduces, so the scope needs stated inclusions and
stated exclusions, each with a reason.

## Decision

v2 is parity with the Nextcloud Mail web client's user surfaces, plus Contacts.

- Scope: every user-facing item in the checklist of nextcloud/mail#13797 (§1–§8, §10),
  plus Nextcloud Contacts parity.
- Excluded, each with its reason:
  - §9 admin settings: a server-administration surface the web admin panel already serves.
  - PGP/Mailvelope (§5.7 PGP row, §6.8 and §6.9 Mailvelope rows, the §7 Security
    Mailvelope card): a browser extension with no native equivalent chosen. The app shows
    an honest notice on PGP mail instead.
  - Debug-only items: "Clear cache", "Report this bug", "Download thread data for
    debugging".
  - Browser mechanics that have native replacements, mapped in `docs/product/parity.md`:
    history back/forward, Ctrl+click new tab, responsive breakpoints, beforeunload.
  - Server-only behaviour with no client surface: OCP Mail Provider, junk/ham reports,
    user migration, AI listeners.

## Consequences

- The scope is enumerable: the parity matrix in `docs/product/parity.md` can list every
  row of the checklist and say where each one lands, so "done" is checkable rather than
  argued.
- The cost is the size: parity with the web client plus Contacts is the whole v2 roadmap,
  and every exclusion above forecloses that feature for v2 — PGP mail gets a notice, not
  decryption.
- ADR-0012's "no composer" boundary is gone; composing, sending and everything around
  them are in scope.

## Alternatives considered

**Keep growing by picked features.** No yardstick; every review reopens scope. The
checklist exists and makes parity auditable.

**Include PGP via a native OpenPGP implementation.** No implementation was chosen, and
Mailvelope is a browser extension with no native equivalent. A notice is honest; a
half-implementation is not.

**Include §9 admin settings.** The web admin panel already serves administrators; this
client serves users.

## Revisit when

A native OpenPGP implementation is wanted, or the client needs to administer servers.
