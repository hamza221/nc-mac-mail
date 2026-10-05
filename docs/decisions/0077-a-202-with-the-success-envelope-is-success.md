<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0077: A 202 carrying the success envelope is a success, not a sync in progress

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-16, while replaying the drafts and outbox fixtures through `MailClient`

## Context

v1 called one controller that answers 202: `MailboxesController::sync`, whose
`IncompleteSyncException` becomes `JsonResponse::fail([], 202)` — "the server took the work
and is not done". `MailClient.error(for:data:endpoint:)` therefore mapped *every* 202 to
`MailError.syncInProgress`, and the sync engine owns asking again.

v2 calls six more routes that answer 202, all on success (`DraftsController::update`,
`destroy`, `move`; `OutboxController::update`, `send`, `destroy` — read in the live server's
source and recorded): `{"status":"success","data": <message | "Message deleted" | "Message
sent" | "Message moved to IMAP">}`. Under the v1 mapping, updating a draft, deleting it and
**sending a message** would all throw `syncInProgress` — and a send that "failed" that way
would be replayed by the drainer and go out twice.

## Decision

A 202 is a success when its body is the success envelope (`"status": "success"`), and
`syncInProgress` otherwise — the fail envelope, `[]`, or an empty body. The rule lives in
`MailClient.error(for:data:endpoint:)`, the one status table, next to the 400 that is
really `mailboxNotCached`, which already reads the body for the same reason.

## Consequences

- The drafts and outbox endpoints decode their envelopes like any other success
  (`V2EndpointDecodingTests` replays each with status 202).
- The v1 behaviour is unchanged: sync's 202 carries the fail envelope, and the existing
  `StatusMappingTests`/`RetryTests` 202 cases (body `[]`) still map to `syncInProgress`.
- A future controller that answers 202 with the success envelope to mean "accepted, not
  done" would read as done. None does in Mail 5.12; the status table is the place to
  special-case one if it appears.

## Alternatives considered

**A per-endpoint flag (`acceptedMeansInProgress`) on `Endpoint`.** Precise, but it adds a
field every factory must set right, for a distinction the body already carries. The body
check needs no new state and cannot be forgotten on a new endpoint.

**Map 202 to success for everything but `sync`, by endpoint name.** Couples the status
table to one name string; the envelope is the server's own statement of the outcome.

## Revisit when

Mail changes either shape — sync answering a success envelope with 202, or a draft or
outbox route answering 202 with something else.
