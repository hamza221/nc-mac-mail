<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-19 — Test harness v2

**Wave 1, continuous. Size: M.**

## Goal

Fake transport and recorder coverage for every new route and for DAV.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../testing-strategy.md](../testing-strategy.md)
- [WS-16-api-surface.md](WS-16-api-surface.md) and
  [WS-17-dav-and-formats.md](WS-17-dav-and-formats.md) — the routes you must cover

## You own

`Packages/NCMailTestSupport/**`, `Scripts/record-fixtures.sh`

## Build

- Your first commit updates [../testing-strategy.md](../testing-strategy.md) with the
  behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

Deliverables:

- `FakeTransport` matchers for DAV methods (PROPFIND, REPORT, MKCOL, PROPPATCH) and
  multipart bodies.
- `Scripts/record-fixtures.sh` targets for each WS-16 route and for CardDAV/CalDAV.
- A documented rule in [../testing-strategy.md](../testing-strategy.md): **send fixtures are
  recorded by sending to the test account's own address only.**

## Acceptance

- Each new fixture is recorded from the live server; nothing is hand-written.

## Out of scope

The endpoints themselves and their decode tests (WS-16). The DAV client and its tests
(WS-17). Store query tests (WS-18). Other workstreams append their own fixture files under
`NCMailTestSupport`'s fixture directory (standing exception 4); you own the tooling, not
their fixtures.

## Report

Additionally: any route the recorder could not capture from the live server and what stands
in for it.
