<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Definition of done

*A workstream is done when every one of these is true. Not most of them.*

## Build

- [ ] `make build` clean — `swift build -Xswiftc -warnings-as-errors` in every package.
      The flag lives in the command, not the manifest
      ([ADR-0016](../decisions/0016-warnings-as-errors-at-the-build-command.md)).
- [ ] `make build-app` clean, if the app target was touched. Not bare `xcodebuild`: it needs
      the `SUPPRESS_WARNINGS=NO` that the Makefile adds.
- [ ] Swift 6 language mode, strict concurrency, no new `@unchecked Sendable`, no new
      `@preconcurrency import`.
- [ ] No new third-party dependency without an ADR.

## Tests

- [ ] New logic has unit tests. "Logic" means anything with a branch in it.
- [ ] New decoding has a test against a **recorded** fixture, not a hand-written one
      ([testing-strategy.md](testing-strategy.md)).
- [ ] New database work has a migration test and a query test.
- [ ] New sync or queue behaviour has a fake-transport test, including its failure path.
- [ ] `swift test` passes in every touched package.
- [ ] Tests do not sleep, do not hit the network, and do not depend on wall-clock time.

## Correctness on the real thing

- [ ] The manual checks in the brief were run against a live Nextcloud instance and the
      output is in the pull request.
- [ ] The offline path was exercised by actually turning the network off, not by mocking
      it — at least once per workstream that claims one.

## Documentation

- [ ] Any decision another agent could have made differently has an ADR.
- [ ] Any document this work proved wrong is corrected **in the same pull request**.
- [ ] `docs/feedback/library-feedback.md` has an entry, or the report says "nothing new"
      and means it.
- [ ] Public types have doc comments saying *why*, not restating the signature.

## Style

- [ ] `make lint` clean. That is `swift format` (a toolchain subcommand, not a separate
      binary) and `swiftlint`, using the configuration WS-00 set up.
- [ ] No `print`. `OSLog`, with `.private` on anything that could carry user data.
- [ ] No force unwrap outside tests, except where a comment proves the invariant.
- [ ] No `Image(systemName:)` outside the one `MailSymbol` mapping file
      ([../reference/ui-components.md](../reference/ui-components.md)).
- [ ] No hard-coded colours, spacings or radii. `theme.colors`, `theme.metrics`.
- [ ] Accessibility labels on every control. The library makes most of this mandatory;
      the rest is on you.

## Security

- [ ] No credential, token, subject, address or body in any log, at any level.
- [ ] No network call outside `NCMailNet`.
- [ ] No view reading the network directly. **The network only writes to the database.**
- [ ] If the workstream touched the WebView, the checklist in
      [../architecture/security.md](../architecture/security.md#review-checkpoints) was
      walked line by line.

## The report

- [ ] The pull request body follows the template in
      [workstreams.md](workstreams.md#report-template) — built, decisions, surprises,
      library feedback, what the next workstream needs, verification.

## What is explicitly not required

- Snapshot tests for app views. The library covers its own components; app-level snapshots
  are brittle and we are not paying for them in v1.
- 100% coverage. Cover the branches, not the lines.
- Performance optimisation without a measurement. If it is slow, measure it, write the
  number down, then fix it.
