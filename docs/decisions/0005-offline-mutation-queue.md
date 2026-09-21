# ADR-0005: Queue mutations locally and replay them

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Product owner

## Context

With a full local mirror, reading works offline. Triage — which is what this app is *for*
— would not, unless mutations are queued. A mail client that shows you a train's worth of
mail and refuses to let you archive any of it is a worse product than one that shows you
nothing.

## Decision

Every mutation is **one local transaction**: apply to the mirror and append to
`pendingOperation`, atomically. A drainer replays queued operations to the server, in
order, per account, with backoff. Online and offline are the same code path; offline is
just the drainer having nowhere to send things yet.

Payloads store absolute intent (`{"seen": true}`), never deltas, so replay is idempotent
and operations collapse.

Design: [../architecture/offline-queue.md](../architecture/offline-queue.md).

## Consequences

- Triage works offline and survives quit, relaunch and reconnect.
- The UI never waits for a request: the list updates from the local write.
- Optimistic mutation gets a correct rollback story, because the queue records what was
  intended and what it was based on.
- Sync must run **after** the drain, or a sync will overwrite a not-yet-sent change and the
  user watches their archive undo itself. That ordering is enforced by `SyncScheduler` and
  is the single most important sequencing rule in the app.
- Conflicts become possible and need written rules, which they have.
- Failure must be surfaced without becoming noise: nothing under five attempts, then one
  aggregate indicator with retry and discard. Never a modal, never a per-message badge.
- Sign-out with a non-empty queue has to ask rather than assume.

## Alternatives considered

**Mutations require the network.** Simpler, ships a week sooner, and makes the flagship
scenario ("triage on a train") impossible. Rejected by the product owner.

**Local write plus fire-and-forget request.** Optimistic without durability: quit before
the request lands and the local state is wrong forever, silently. The failure mode is
invisible data divergence, which is the worst kind.

**CRDT-style merge.** IMAP flags are not a CRDT and the server is authoritative. Enormous
machinery for a problem that last-writer-wins with a stated rule solves.

## Revisit when

Compose arrives in v1.1. A queued send is a different animal — it needs a visible outbox,
a cancel window and delivery confirmation — and probably deserves its own record rather
than a new `kind` on this one.
