# ADR-0012: v1 is read and triage; no composer

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Carried over from `plan/macos-client.md`, unchanged

## Context

The obvious objection to a mail client that cannot send mail deserves a straight answer.

`NextcloudUI` defers `NCRichContenteditable` and `NCRichText` to v1.1. The roadmap is
explicit about why: `NCRichContenteditable` needs `NSTextView` bridging and is three to
four person-weeks by itself. So a composer today is either plain text — which nobody wants
for work mail — or an `NSTextView` bridge this app writes, owns and maintains, in a project
whose purpose is to *evaluate* the component library rather than to grow a parallel one.

Compose also drags in drafts, the outbox, scheduled send, signatures, aliases, recipient
autocomplete, attachment upload, and warnings about missing subjects. That is a second
application.

## Decision

v1 does read and triage. No compose, reply, forward, drafts or outbox. No account setup —
accounts are created in the web client. The full exclusion list is in
[../product/overview.md](../product/overview.md).

## Consequences

- v1 is achievable and the library evaluation happens early, which is the point of the
  exercise.
- The read path is proven — and it is the path the mirror, the sync engine and the
  rendering model all live on — before anything is built on top of it.
- Users need the web client for sending, which is a real limitation and must be said
  plainly in the app's own description rather than discovered.
- The mutation queue is built for triage in a way that a queued *send* will want to extend
  ([ADR-0005](0005-offline-mutation-queue.md)) — that extension is deliberately left for
  when compose is designed, not guessed at now.

## Alternatives considered

**Plain-text composer in v1.** Cheap, and it makes the app look like it supports sending
when it supports a fraction of it. Worse than an honest gap.

**`NSTextView` bridge in v1.** Three to four weeks on the one component the library says it
will eventually provide. Building it here means either throwing it away or becoming the
place it lives.

## Revisit when

`NCRichContenteditable` lands, or the read path is proven and the team decides the bridge
is worth owning. The mirror makes offline compose and a durable outbox easier than they
would otherwise be, so the second version starts ahead.
