<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0045: `NCMailStore` grows the queue DAO and the four readers the views worked around

**Status:** Accepted — supersedes [ADR-0038](0038-the-message-view-observes-the-thread.md),
[ADR-0042](0042-the-list-watches-one-mailbox-through-its-account.md) and
[ADR-0043](0043-the-queue-names-the-storage-it-needs.md)
**Date:** 2026-09-23
**Decided by:** the store-DAO pass, executing the replacements those three records named

## Context

[ADR-0034](0034-the-store-returns-its-own-sequence.md) made `MailStore.read` and
`MailStore.write` internal, and named the standing cost itself: "the next thing that wants a
query the store does not have needs a DAO rather than a closure". Four workstreams then hit
that cost and, correctly, wrote down a workaround rather than reaching into someone else's
package.

- **WS-06** could not write ADR-0005's `store.write { applyLocally; insert }` from
  `NCMailSync`, so the queue talks to an `OperationStoring` protocol whose only conformance
  is in the test target (ADR-0043). The consequence is the one that matters: **nothing
  outside `NCMailSync` can construct a `MutationQueue`**, so the queue is unreachable from
  the app and WS-10 and WS-12 are blocked.
- **WS-09** observes the whole *thread* to notice one body arriving (ADR-0038).
- **WS-08** observes every mailbox of an account and filters to watch one (ADR-0042).
- **WS-09** decodes `Envelope` back out of `message.rawJSON` to list recipients, because
  `messageAddress` has no reader.
- **WS-09 and WS-08 both** found that the `avatar` table has no DAO, and
  [ui-components.md](../reference/ui-components.md#avatar-loading) documents a
  `store.avatar(for:)` that does not exist.

Each of those records named its replacement. This is the change that writes them.

## Decision

`NCMailStore` gains one new query file and four readers, and the workarounds come out.

**`Queries/MailStore+Operations.swift`** holds `enqueue(_:applying:)`,
`pendingOperations(accountId:)`, `markInFlight(ids:)`,
`reschedule(ids:attempts:nextAttemptAt:lastError:)`, `finish(ids:applying:)` and
`threadMessages(accountId:rootId:)`. The bodies are WS-06's, moved unchanged from
`NCMailSyncTests/OperationStoreSupport.swift`; the only edits are that `questionMarks`
becomes the store's own `databaseQuestionMarks`, and `store.read`/`store.write` become
`dbQueue.read`/`dbQueue.write`. `LocalEffect` and `MessageFlagColumns` move down beside
them, because a store method cannot take a type from a module above it, and
`MessageFlagColumns` is what keeps a flag key nobody modelled out of the UPDATE.

`OperationStoring` is deleted. `MutationQueue` and `OperationDrainer` take a `MailStore`.

**`observeBody(messageId:) -> StoreObservation<StoredBody?>`**, which is what the message
view wanted: `upsert(body:for:)` writes the body row, the attachments and
`message.bodyState` in one transaction, and two of those three tables are in this query's
region.

**`observeMailbox(id:) -> StoreObservation<MailboxRecord?>`**, which is what the message
list, the sidebar and the storage panel all wanted: one row, not the account's.

**`addresses(messageId:) -> [MessageAddressRecord]`**, in header order — `from`, then `to`,
`cc`, `bcc`, `replyTo`, each in the order the header listed them. A read and not an
observation, deliberately: `messageAddress` is `WITHOUT ROWID`, SQLite's update hook never
fires for it, and a `ValueObservation` over it could never deliver a second value
([ADR-0025](0025-rowid-tables-for-anything-observed.md)). The rows are rewritten by the
same transaction that writes the envelope, so a caller observing the message re-reads these
and is never stale.

**`avatar(for:) -> AvatarRecord?`**, matched case-insensitively. It answers three different
facts and the caller needs all three: nil for an address nobody has asked about, `missing`
for one the server answered 404 for, and bytes otherwise.

Two things follow that a reviewer could reasonably have decided the other way.

**`avatar(for:)` returns a row, not an `Image`.** `ui-components.md` wrote the loader as
`store.avatar(for:) -> Image?`. `NCMailStore` may not import SwiftUI, and a `Sendable`
image type crossing that boundary is the same kind of leak ADR-0034 closed. The conversion
lives in the app, in `Views/Message/AvatarLoader.swift`, as
`MailStore.avatarLoader(for:) -> (@Sendable () async throws -> Image)?` — the shape
`NCAvatar` and `NCUserBubble` take. It is under `Views/Message/**` because there is no
neutral folder for something both columns use; `MessageListStore` re-exposes it so the row
view never names it.

**The message view now runs two observations, not one.** The body drives the body area; the
thread still drives the strip underneath it, and it is also what notices `bodyState` going
to `.failed` — that column is on `message`, which `observeBody` does not track, and a fetch
that gave up writes it and no body row at all. Collapsing both into one observation would
mean either re-reading the body on every `message` commit (what ADR-0038 did) or losing the
Retry affordance.

## Consequences

- **The queue is reachable from the app.** WS-10 and WS-12 are unblocked:
  `MutationQueue(store: store, drainer: drainer)` compiles anywhere `NCMailStore` is
  visible.
- The bodies are covered twice, which is right: `NCMailSyncTests` keeps every behavioural
  test of the queue (what is sent, what a 404 does, what Discard reverts) and they now run
  against `MailStore` directly, and `NCMailStoreTests/OperationQueryTests.swift` adds nine
  tests about the statements themselves — that one transaction is one transaction, that a
  refused insert rolls the local change back with it, that a flag key with no column reaches
  no UPDATE.
- `MessageFlagColumns` is public API of `NCMailStore` now. It is a mapping between the
  server's flag spellings and this schema's column names, which is a store fact; the
  alternative was passing column names in from `NCMailSync`, which is how an UPDATE gets a
  column name out of a payload.
- `MessageViewModel` loses `lastObservedBodyState` and its re-read of the body, and
  `MessageListStore.observeMailbox(id:)` loses its preliminary read and its `first(where:)`.
- The header's recipients come from the table that holds them, so a message whose `rawJSON`
  the server changed shape on still lists its recipients.
- [ADR-0044](0044-the-queue-type-is-not-called-operationqueue.md) lists `OperationStoring`
  among the names that were keeping theirs. That type no longer exists; nothing else in that
  record changes.
- Nothing writes the `avatar` table yet, so every address still draws coloured initials. The
  difference is that it draws them because the row is absent rather than because there was
  no way to look, and the missing half — a writer, and whatever fetches
  `GET /api/avatars/image/{email}` — is now the only thing in the way.

## Alternatives considered

**Keep `OperationStoring` and add a conformance in `NCMailSync`.** It would unblock the app
with a smaller diff, and it keeps a protocol whose only purpose was to describe a DAO that
now exists. ADR-0043 said the port "is not a general abstraction and is not meant to grow.
It has exactly the methods the queue calls, and it is deleted rather than extended."

**Give `observeBody` the message row too, so it could carry `bodyState`.** It would collapse
the two observations back into one. It also widens the query's region to `message`, which
during a backfill commits every batch — so the body observation would fire constantly for a
column it does not read. The thread observation is already watching that region for the
strip.

**Make `addresses(messageId:)` an observation for symmetry.** It cannot work:
`messageAddress` is `WITHOUT ROWID` and would silently deliver exactly one value, which is
worse than a read because it looks live.

**Leave `avatar(for:)` out until something writes the table.** Defensible — a reader with no
writer reads nothing. Rejected because two workstreams asked for it independently, the
documented loader shape needs it to exist before anything can be wired, and the table has
been in the schema since WS-03.

## Revisit when

Something fetches avatars, and `upsert(avatar:)` joins the reader. Or when
[ADR-0037](0037-the-queue-is-read-twice-around-the-sync-write.md)'s replacement —
`upsert(envelopes:preservingPendingOperationsFor:)` — lands, which is the last of the
missing-DAO workarounds and the one this change deliberately did not touch.
