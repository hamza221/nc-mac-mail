<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0054: Keychain attributes at launch, passwords off the main thread

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-13, after `make test-app` stopped returning and a `sample` said why

## Context

`AppSession.init()` read every account out of the Keychain synchronously, on the main thread,
before `WindowGroup` drew anything. The comment above it explained why: `Keychain` is a
synchronous API, and populating `accounts` in `init` means `needsSignIn` never answers "yes"
for a frame to a user who is signed in.

Then `make test-app` began hanging with "The test runner hung before establishing connection",
and `sample` on the stuck host process showed the main thread parked here:

```
AppSession.init(store:initialTheme:)         AppSession.swift:52
 static AppSession.accountsFromKeychain()    AppSession.swift:159
  static Keychain.load(server:loginName:)    Keychain.swift:49
   SecItemCopyMatching
    ...SSGroupImpl::decodeDataBlob
     ClientSession::decrypt → mach_msg → securityd
```

Reading the password *decrypts* the item, and decryption checks the item's access control
against the running binary. When they do not match, `securityd` asks the user, and
`SecItemCopyMatching` does not return until somebody answers. This project signs ad hoc
([ADR-0018](0018-ad-hoc-signature-in-the-checked-in-project.md)) and an ad-hoc signature
changes on every build, so a mismatch is the ordinary case on a development machine, and the
app-hosted test bundle launches the real app ([ADR-0029](0029-app-test-target-borrows-its-modules-from-the-host.md)).
No window existed yet to show the prompt over, and nothing could answer it in a test run.

It is not only a test problem. On the main thread this is a frozen launch: no window, no menu
bar, no way to quit but Force Quit, for as long as the dialog goes unanswered.

Enumerating accounts is a different call. `Keychain.allAccounts()` asks for
`kSecReturnAttributes` and no data, which does not decrypt anything and therefore cannot block
on consent.

## Decision

Split the launch read in two along that line.

`AppSession.init()` calls `Keychain.allAccounts()` and keeps the count. That is enough for
`needsSignIn`, which is the only thing the first frame needs, and it cannot block.

`AppSession.start()` reads the passwords on `Task.detached`, builds one `MailClient` per
account there, and assigns `accounts` back on the main actor. `AccountSession` is
`nonisolated` and `Sendable` so it can cross that boundary; the app target defaults to
`@MainActor`, so the annotation is the change that lets the value be built off it.

## Consequences

- A returning user still sees three columns on the first frame. They are drawn from the
  mirror, which is the whole point of a local-first app: the columns do not need a client.
- A consent prompt, when one appears, appears over a window instead of instead of one, and
  the app stays responsive while it is up. The account whose password has not been read yet
  simply has no coordinator until it is — which is exactly the state ADR-0047 already
  handles, because the engine starts from rows and not from Keychain entries.
- `make test-app` runs again. It was hanging for every app-side workstream on this machine,
  not only this one.
- `needsSignIn` is now two facts rather than one: no accounts loaded **and** no stored items.
  Sign-out has to clear both, which is a note for WS-12.
- Nothing here makes `Keychain` itself async. `NCMailNet` belongs to WS-01, and the fix that
  is this workstream's to make is not to call a blocking API from the main thread.

## Alternatives considered

**Leave it, and treat the hang as a machine artifact.** It is not: every developer running an
ad-hoc build hits the ACL mismatch, and the failure mode is a frozen app with no window.

**Load lazily on first use instead of at `start()`.** Moves the same blocking call to an
arbitrary later moment, which is worse: it would be the first triage action, in the middle of
a gesture.

**Make `Keychain.load` async in `NCMailNet`.** The right long-term shape, and it is WS-01's
file. Written up here so that workstream can take it.

**Answer the prompt once and store the credential unprotected.** Not a choice worth having.

## Revisit when

`NCMailNet` grows an async Keychain API, at which point the detached task here is one `await`
instead.
