<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0076: A truncated sync-collection is a flag on a successful result, not an error

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-17, while building `DAVClient.syncCollection` against recorded answers

## Context

RFC 6578 lets a server stop a `sync-collection` REPORT early. §3.6 says the server then
returns the changes it has, a sync token for that point, and a response for the
request-URI with status `507 Insufficient Storage` inside the 207 multistatus. The WS-17
brief names "a 507 truncated sync" as an acceptance case, which reads as if it were an HTTP
error.

What Nextcloud (sabre/dav) actually sends was recorded rather than assumed:
`Scripts/record-fixtures.sh` asks for a sync with `<d:limit><d:nresults>1</d:nresults>`,
and `dav-sync-truncated.xml` is the answer — HTTP **207**, one ordinary member response, an
extra bare `<d:response>` whose href is the collection itself with
`<d:status>HTTP/1.1 507 Insufficient Storage</d:status>`, and a valid `<d:sync-token>`. The
HTTP status is never 507. That matches the RFC's in-band shape.

The client does not send a limit itself. Whether the server truncates an unlimited request
on its own (a server-side cap on rows per sync) was not observed on the test instance; the
code must not depend on it either way.

## Decision

`syncCollection(_:token:)` returns `DAVSyncChanges(changed:removed:newToken:truncated:)`.
A response with status 507 sets `truncated` and is neither a change nor a removal; a 404
response is a removal; every other member response with a propstat is a change. The
`newToken` from a truncated answer is kept and is valid — the caller (WS-24's contacts and
calendar sync) stores it and calls again with it until `truncated` is false.

Truncation is never thrown. `DAVError` is reserved for answers the caller cannot use: a
non-2xx HTTP status (mapped by `DAVError.status(_:data:)`, with sabre's `d:error` body as
diagnostics), or a multistatus with no sync token (`.invalidResponse`, because without a
token there is nothing to resume from).

An HTTP-level 507 (the server out of disk on any verb) stays an ordinary
`DAVError.server(status: 507, …)` — a different condition that happens to share the
number.

## Consequences

- The loop lives in the sync engine, which owns persistence of the token between rounds;
  the client stays one request per call and never retries (networking.md, DAV section).
- A truncated round is still progress: its changes can be applied and its token persisted
  before the next request, so a crash mid-loop resumes instead of restarting.
- `DAVClientTests.truncatedSyncSurfacesTheFlagAndKeepsTheToken` pins the recorded shape;
  `syncWithoutATokenInTheAnswerThrows` pins the one multistatus that is an error.

## Alternatives considered

**Throw a `.truncated(partial:token:)` error.** Makes the normal "large address book"
path an exception path, and forces every caller to catch to get at data that is valid.

**Loop inside `syncCollection` until complete.** Hides an unbounded number of requests
behind one call, holds every round's changes in memory, and loses progress on a crash —
the engine cannot persist an intermediate token it never sees.

## Revisit when

Nextcloud starts truncating with an HTTP-level status or without a token, or WS-24 needs
the client to send `<d:limit>` itself to bound memory per round.
