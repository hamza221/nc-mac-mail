<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0047: The account row starts the engine, not the Keychain entry

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-13, wiring the columns and finding that the obvious loop does not survive a
launch with no network

## Context

Nothing in the app called `MirrorCoordinator.discoverAccounts(store:client:identity:)`, so no
`account` row was ever written and `store.observeAccounts()` answered with an empty array even
with valid credentials in the Keychain. WS-07 reported an empty sidebar; the sidebar was
right.

The shape WS-04 and WS-05 wrote for the app is "per `Keychain.allAccounts()` entry, call
`discoverAccounts`, then start one `MirrorCoordinator` per record it returns, and one
`SyncScheduler` per account". Written literally, that is one loop:

```swift
for account in Keychain.allAccounts() {
    let rows = try await MirrorCoordinator.discoverAccounts(...)
    for row in rows { start(row) }
}
```

which starts nothing at all when `discoverAccounts` throws. It throws on the ordinary offline
launch, on a server that is down, and on an app password that was revoked. A local-first app
whose whole claim is that it works without a network would then have had a sync engine that
only starts when the network answers, and a message list whose "prioritise this body" button
does nothing until it does. The mirror is already full of rows in that state.

## Decision

Discovery and starting are separated by the database, like everything else here.

`AccountEngine` observes `store.observeAccounts()` and starts one `MirrorCoordinator`, one
`OperationDrainer` and one `SyncScheduler` for every row it sees. `discoverAccounts` runs
once per Keychain entry, in its own task, and its only job is to write rows. It returns
`[AccountRecord]`, and the engine ignores the return value: the observation delivers the same
rows a moment later.

A row is matched back to the credentials that can talk to it by the `(serverURL, loginName)`
pair the row carries (ADR-0033), which is the pair the Keychain item is keyed by.
`AccountSession.identifier(server:loginName:)` spells that key once.

## Consequences

- An offline launch starts every account's engine from rows already in the mirror. The
  schedulers see `isOffline` through `apply(conditions:)` and wait; nothing has to be
  restarted when the path comes back, because `MirrorConditions` is already pushed to them.
- One account's failure is one task's failure. A revoked app password raises the 401 modal for
  that account and the other account's coordinator never learns about it.
- Signing in adds a Keychain identity and kicks off one discovery. The row arrives through the
  same observation as every other row, so `signedIn` has no second start path.
- A row whose Keychain entry could not be read this launch is logged and skipped rather than
  started with no credentials. It is the same account the sidebar will draw from the mirror;
  it simply does not sync until the entry can be read.
- The engine is one more observation of `account` — the sidebar already runs its own. Two
  observations of the same four rows is cheap, and sharing one would have meant the sidebar
  owning the sync engine's lifetime.

## Alternatives considered

**The literal loop: discover, then start what it returns.** One less observation and one less
identity lookup. Rejected because "no network at launch" is a first-class state in this app,
not an error path.

**Start a coordinator per Keychain entry and let it find its own account id.** A coordinator
takes a local account id and a local id only exists once a row does (ADR-0033), so this is the
decision that ADR already made.

**Have `discoverAccounts` start the coordinators itself.** It lives in `NCMailSync`, which
cannot see `AppStatus` or the Keychain, and it would make one function both a write and a
lifecycle. Rejected.

## Revisit when

Sign-out lands (WS-12). Removing a row is already handled — the observation stops that
account's coordinators — but removing the Keychain entry without removing the row would leave
an account the engine keeps skipping, so the two have to happen together.
