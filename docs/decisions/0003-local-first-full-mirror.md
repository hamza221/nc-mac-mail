<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0003: Keep a complete local mirror and read from it always

**Status:** Accepted — **supersedes** the "No local database" decision in `plan/macos-client.md`
**Date:** 2026-09-21
**Decided by:** Product owner, explicitly, after the original plan was written

## Context

`plan/macos-client.md` decided against a local database, and the reasoning was sound as far
as it went:

> No local database. The server already caches IMAP in its own tables and every list
> endpoint is paginated. State lives in one `@Observable` store for the session.

That is a good decision for a client whose job is to display what the server has. It is the
wrong decision for the client we want, and the difference is not performance — it is what
the product *is*.

A client that fetches on demand:

- shows nothing useful on a plane, in a tunnel, or on hotel wifi;
- cannot search your mail, because server-side IMAP body search is slow enough that
  Nextcloud Mail hides it behind a per-account opt-in;
- puts a network round trip between a keypress and a message, which is the difference
  between a mail client that feels native and one that feels like a web page in a window;
- loses everything on quit, so every launch is a cold start.

Apple Mail, Outlook, Thunderbird and the Nextcloud Files desktop client all mirror. It is
what "desktop client" means to the people who ask for one.

## Decision

**Every message in every subscribed mailbox is downloaded and kept locally, and every read
is served from the local copy.**

- On first sign-in, a two-stage backfill: envelopes for every subscribed mailbox (fast,
  the app is usable in seconds), then every body behind it, newest first.
- After that, incremental sync carries only what changed.
- The local copy is **always preferred** over the server. The network never renders; it
  only writes to the database.
- Nothing expires and nothing is evicted automatically
  ([ADR-0008](0008-no-automatic-eviction.md)).

Design: [../architecture/local-mirror.md](../architecture/local-mirror.md).
Schema: [../reference/schema.sql](../reference/schema.sql).

## Consequences

**What it buys**

- Reading, listing, threading and searching work offline and instantly.
- Local full-text search across every mirrored mailbox and account — a capability the web
  client cannot practically offer.
- Triage offline, through the mutation queue ([ADR-0005](0005-offline-mutation-queue.md)).
- A cheaper steady state than the web client, which re-fetches bodies whenever its
  600-second server-side cache expires.
- Mirroring is *more* private than browsing: the server blocks remote images before we
  store the HTML, so a full backfill fires zero tracking pixels.
- Unified inbox, cross-account search and Spotlight integration become `WHERE` clauses
  rather than projects.

**What it costs**

- A storage layer, a backfill engine, a sync engine and a mutation queue — four
  workstreams that would not otherwise exist. Roughly half of v1.
- Disk: about 800 MB for a 50,000-message account
  ([../architecture/local-mirror.md](../architecture/local-mirror.md#sizing-so-nobody-is-surprised)).
- A one-time server cost: one IMAP fetch-and-parse per message, bounded to four concurrent
  requests and pausable. The steady state afterwards is cheaper than not mirroring.
- Mail at rest on the user's disk, which is a security decision of its own
  ([ADR-0006](0006-data-at-rest.md)).
- Whole classes of bug that a stateless client cannot have: staleness, divergence,
  partial backfills, conflicts. The answer is the deep reconcile in
  [../architecture/sync-engine.md](../architecture/sync-engine.md), and tests for every one
  of them.

**What it forecloses:** nothing. Every v1.1 feature is easier with the mirror than without.

## Alternatives considered

**Envelopes only.** Half the work, and the list is a tease: you can see mail you cannot
open. Rejected by the product owner.

**Bodies for a rolling window (last 30 days).** The usual compromise. It fails on exactly
the case that makes search valuable — the message from eight months ago — and it needs an
eviction policy, which is a permanent source of "where did my mail go".

**Cache bodies as they are read, keep them forever.** Cheapest useful version, and the
mirror is never complete, so search is never complete and offline is a lottery over what
you happened to open.

## Revisit when

Nothing plausible reverses this. The parameters — which mailboxes, how deep, how fast —
are tuned in ADRs 0007, 0008 and 0015 without touching this one.
