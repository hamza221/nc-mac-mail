<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-04 — Mirror coordinator and two-stage backfill

**Wave 2, after WS-01, WS-02, WS-03. Size: L. This is the heart of the product.**

## Goal

From a fresh sign-in to a complete local copy of every subscribed mailbox — usable in
seconds, complete eventually, resumable always, and polite to the server throughout.

## Before you start

- [../../architecture/local-mirror.md](../../architecture/local-mirror.md) — **all of it**
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0007-subscribed-mailboxes-only.md](../../decisions/0007-subscribed-mailboxes-only.md)
- [../../decisions/0014-singleton-enumeration.md](../../decisions/0014-singleton-enumeration.md)
- [../../reference/api-payloads.md](../../reference/api-payloads.md) — traps 1 and 2
- [../../product/user-stories.md](../../product/user-stories.md) — S-02

## You own

`Packages/NCMailSync/Sources/NCMailSync/Mirror/**`

## Build

```swift
public actor MirrorCoordinator {
    // `accountId` is the mirror's own, not the server's, and a row has to exist first:
    // ADR-0033. `discoverAccounts` is what creates the rows and hands back their ids.
    public static func discoverAccounts(
        store: MailStore, client: MailClient, identity: ServerIdentity
    ) async throws -> [AccountRecord]

    public init(store: MailStore, client: MailClient, accountId: Int64)
    public func start() async          // resumes wherever the database says it stopped
    public func pause() async
    public func resume() async
    public func prioritise(messageId: Int64) async    // user opened it; jump the queue
    public var progress: AsyncStream<MirrorProgress> { get }
}
```

**Bootstrap.** `GET /api/accounts` → upsert, keyed by the signed-in login. Per account
`GET /api/mailboxes?accountId=` — the *server's* account id, read off the account row —
→ upsert, deriving `isSubscribed` and `isSelectable` from `attributes`, and setting
`isMirrored = isSubscribed && isSelectable`. Every id in a URL from here on is a `remoteId`
and every id written to a row is local ([ADR-0033](../../decisions/0033-accounts-have-a-local-identity.md)).

**Stage 0, priming.** `POST /api/mailboxes/{id}/sync {"ids":[],"init":true}` per mirrored
mailbox. 200 → store the returned envelopes (they are the first page, free). 202 → retry
with backoff, not an error. 428 → retry with `init: true`. Failure marks the mailbox and
moves on; **one slow mailbox never blocks the account**.

**Stage 1, envelopes.** Per mailbox, paginate
`GET /api/messages?mailboxId=&view=singleton&limit=100&cursor=` until a short page.
`view=singleton` is mandatory — the threaded view returns thread heads only and you would
mirror a mailbox missing every reply, silently.

Write the page **and** `mailbox.envelopeCursor` in one transaction. That is what makes a
kill -9 harmless.

**Stage 2, bodies.** Account-wide queue, newest first across mailboxes. Per message:
`GET /api/messages/{id}/body`, then `GET /api/messages/{id}/html?plain=true` when
`hasHtmlBody`. One transaction writes `messageBody`, `attachment` rows, the FTS row and
`bodyState = 'present'`.

**Etiquette, all four mandatory:**

1. Two concurrent body fetches per account, four in total.
2. `prioritise(messageId:)` jumps the queue and pauses one worker.
3. 429/503 → honour `Retry-After`, halve concurrency for ten minutes.
4. Low Power Mode, or `NWPath.isExpensive`/`isConstrained` → pause **stage 2 only**. Stage
   1 is cheap and makes the app usable, so it keeps going.

**Progress** is computed from the database (the query is in the architecture document), so
it is correct after a crash and needs no bookkeeping.

## Acceptance

Against a real account of at least 5,000 messages:

- Sign in; the sidebar populates in seconds and the inbox's first page is readable well
  before the mirror completes.
- Quit mid-stage-1; relaunch; it resumes at the right cursor, re-fetching at most one page.
- Quit mid-stage-2; relaunch; it resumes without re-fetching a single stored body.
- Pull the network; it pauses; reconnect; it resumes. No error cascade, no lost progress.
- Open an un-backfilled message; it appears promptly and the queue carries on afterwards.
- Unsubscribed mailboxes are **not** backfilled; subscribing to one in the web client
  starts it on the next mailbox sync.
- A mailbox that 428s is primed and mirrored without the user seeing anything.
- Server logs (or a proxy count) show concurrency never exceeded the budget.

And in fake-transport tests: every failure path above, plus a 202 that resolves on the
third try, plus a mailbox whose `/body` 404s.

## Out of scope

Incremental sync (WS-05). Mutations (WS-06). Any view — you publish progress; WS-13
displays it.

## Report

Additionally, the numbers, because they are the first real evidence this design works:
wall-clock time for stage 1 and stage 2 on a real account, total requests, final database
size, and peak memory. Replace the estimates in
[../../architecture/local-mirror.md](../../architecture/local-mirror.md#sizing-so-nobody-is-surprised)
with what you measured, and say what it cost the server.
