<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0080: The recorder exercises mutating routes on scratch objects, and sends only to the account itself

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-19, after extending `Scripts/record-fixtures.sh` to every WS-16 route and the DAV surface against the live dev server

## Context

"Every fixture is a real server response" (AGENTS.md, `docs/delivery/testing-strategy.md`)
was easy to honour while the recorded routes were reads. v2 needs fixtures for creates,
updates, deletes, uploads, snoozes and sends — responses that only exist as the result of a
mutation. Three forces collide:

- A fixture must come from the live server, so the mutation must actually run.
- The recorder is rerun whenever the server changes shape, so a run must not accumulate
  junk or destroy real state — otherwise nobody dares rerun it, and the fixtures fossilise.
- A send fixture requires a real SMTP send, and a recorded send to any third party leaks
  the operator's test traffic (and, with scrubbing off, their address) to a stranger's inbox.

## Decision

Mutating routes are recorded as **scratch-object lifecycles**: the recorder creates a
throwaway object, records each mutation's response against it, and deletes it in the same
run — the create, update and delete responses are themselves the fixtures
(`tag-created.json` → `tag-updated.json` → `tag-deleted.json`, and likewise for aliases,
mailboxes, drafts, outbox messages, quick actions, text blocks, uploaded attachments, a
self-signed S/MIME certificate, a delegation grant to a second server user, and temporary
vCards for the DAV sync fixtures). Mutations of singleton state (signature, preferences,
out-of-office) write a value the run restores or that is already the server's state.

Scratch objects are **self-healing across dead runs**: a run that dies mid-lifecycle must
not break the next one. Scratch names that the server keeps unique carry the run's
timestamp (`FixtureScratch<epoch>` — an IMAP folder the Mail cache has lost sight of
cannot collide with it), leftovers matching the scratch prefix are swept before and after
the lifecycle, and a grant that may survive a dead run is revoked before it is re-created.

Recorded bodies carry **payload, not server internals**: a debug-mode JSON error keeps
`status`, `message`, `type` and `code` but loses its `trace`/`file`/`line`; the install root
is rewritten in HTML error pages; DAV header fixtures drop `Set-Cookie`, `X-Request-Id` and
`X-Debug-Token`. `FixtureBytesTests` asserts all three.

**Send fixtures are recorded by sending to the test account's own address only.** No
recorder target, present or future, puts any other address on a message. The four send
targets — `outbox-sent.json`, `ocs-message-sent.json`, the HTML attachment message behind
`message-body-attachments.json`/`message-html-plain.html`, and the remote-content message
behind `message-remote-images-envelope.json`/`message-html-remote-images.html` — address
the account's own `emailAddress`, which also deposits fresh inbox messages for the next run.

Routes whose mutation cannot be undone or aimed at scratch state — account create/replace/
delete — are not exercised; they stay listed in the script as deliberate gaps rather than
being faked.

## Consequences

- Every rerun of the recorder leaves the account as it found it, modulo three
  self-addressed messages and the Files copies made by the save-to-Files targets; rerunning
  stays cheap, so fixtures stay honest.
- The recorder is no longer read-only: it must not be pointed at a production account.
  The usage comment says so.
- A precondition the dev server cannot meet (LLM off, ManageSieve disabled, notifications
  app absent) records the server's error body under the route's name — that body is
  exactly what the client decodes in that situation, and the run output table names the
  status next to each file.
- Account create/PUT/DELETE have no fixtures until a disposable second mail account exists
  on the test server.

## Alternatives considered

- **Hand-written fixtures for mutations** — forbidden by the rule this repository was
  founded on; the decoder would be tested against a guess.
- **Record mutations once, by hand, outside the script** — unreproducible; the next server
  upgrade leaves no way to re-record without re-deriving every curl invocation.
- **A dedicated throwaway server account for sends** — heavier (provisioning a second
  mailbox) and still sends real mail somewhere; self-addressing gets the same SMTP response
  with zero recipients outside the account.

## Revisit when

The test server gains a disposable second mail account (enables account create/PUT/DELETE
fixtures), or a recorder run is needed against a server where even
self-sends are unacceptable.
