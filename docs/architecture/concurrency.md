<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Concurrency

*Swift 6, strict, from the first commit. Where each kind of work runs, and the four rules
that keep it that way.*

## Settings

Swift 6 language mode, warnings as errors. Toolchain: Xcode 26.6, Swift 6.3.3.

Where warnings-as-errors is asked for is not where you would expect. The packages' manifests
do not carry `.treatAllWarnings(as: .error)`, because Xcode hands every package target
`-suppress-warnings` and swiftc refuses the two flags together. The Makefile and CI pass
`swift build -Xswiftc -warnings-as-errors` instead, which reaches the root package's own
targets and not its dependencies. The app target carries
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, where nothing suppresses anything.
[ADR-0016](../decisions/0016-warnings-as-errors-at-the-build-command.md) has the detail.

Isolation differs by module, deliberately:

| Module | `defaultIsolation` | Why |
| --- | --- | --- |
| `NextcloudMail` (app) | `MainActor` | Matches `NextcloudUI`. Views and stores are main-actor without saying so, and the annotation noise disappears |
| `NCMailCore` | none (`nonisolated`) | Pure value types and functions. Callable from anywhere, cheap |
| `NCMailNet` | none | `Sendable` value types; requests run wherever the caller is |
| `NCMailStore` | none | Database work must not be on the main actor |
| `NCMailSync` | none | Actors of its own |

Setting `defaultIsolation(MainActor.self)` on the packages would be the single most
expensive mistake available here: every database write would hop to the main actor, and
the backfill would fight the scroll view for it.

## Where work runs

```
Main actor                        Actors                      GRDB's own queue
──────────                        ──────                      ────────────────
SwiftUI views                     MirrorCoordinator           write transactions
@Observable stores                SyncScheduler (per account) read transactions
WKWebView + scheme handler        OperationDrainer (per acct) ValueObservation
                                  BackfillWorker pool
```

- **Reads for the UI** arrive as `StoreObservation`, an `AsyncSequence` `NCMailStore`
  publishes over a GRDB `ValueObservation` scheduled on the main actor. A store receives
  fresh values and assigns them; SwiftUI does the rest. The sequence is the store's own
  type, not GRDB's, so nothing above `NCMailStore` links GRDB
  ([ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md)). A value arrives
  after every commit to a table the query reads, changed or not, and a consumer that falls
  behind is handed the newest value, not every one it missed: each is a whole snapshot. A
  consumer whose work per value is expensive compares with the last value it acted on. A
  cancelled iteration is handed nothing more, not even a value already buffered, so a
  replaced observation cannot assign after the one that replaced it.
- **Writes** always go through `DatabaseQueue.write`, off the main actor, one at a time.
  WAL means readers never block on them.
- **Requests** run inside whichever actor asked; `URLSession` is already concurrent.
- **The scheme handler** is called by WebKit on the main thread and must return promptly:
  it hands off to a `Task`, serves from the database when it can, and only then fetches.

## The four rules

**1. No `@unchecked Sendable`.** If a type will not conform, it is the wrong type. The one
place this bites is `WKWebView` and other AppKit objects; those are main-actor by
definition and stay behind `@MainActor` wrappers, never passed to an actor.

**2. Models are value types and `Sendable`.** Every row, payload and DTO. They cross actor
boundaries constantly and must do so for free.

**3. Actors own state, not locks.** `MirrorCoordinator` owns mirror progress in memory
only as a cache of what the database says. No `NSLock`, no `DispatchQueue` for mutual
exclusion, no `@Atomic`. The database is the coordination primitive between subsystems, and
actors are the coordination primitive within one.

**4. Cancellation is honoured everywhere.** Every loop in the backfill and the sync engine
checks `Task.isCancelled` between units of work, so quitting the app, signing out and
pausing are immediate rather than "after this mailbox". A `Task` stored on a store is
cancelled in `deinit`; a `Task` in an actor is tracked and cancelled explicitly.

## Cooperative pools and long work

The backfill is long-running but not CPU-heavy: it is mostly waiting on the network. It
must not occupy the cooperative pool.

- Workers are structured `Task`s inside a `TaskGroup` owned by `BackfillWorker`, bounded at
  the concurrency limits in [networking.md](networking.md#concurrency-budget).
- Between items, `await Task.yield()`, so a burst of quick responses cannot starve the UI.
- Priority: backfill at `.utility`, sync at `.utility`, drain at `.userInitiated`, anything
  the user is looking at right now at `.userInitiated`.
- Nothing is `.background`: macOS will throttle it into next week.

## Observation, precisely

```swift
@MainActor @Observable
final class MessageListStore {
    private(set) var rows: [MessageRow] = []
    private var observation: Task<Void, Never>?

    func show(mailbox: Mailbox.ID, view: ListView, filter: Filter?) {
        observation?.cancel()
        observation = Task { [store] in
            for try await rows in store.observeMessages(mailbox, view, filter) {
                self.rows = rows
            }
        }
    }
}
```

Three things to notice, because each is a bug elsewhere:

- The observation is **replaced**, not added to, when the selection changes. Leaking one
  observation per mailbox click is the classic version of this bug. Cancelling the `Task`
  is enough: the iterator goes with it, and `StoreObservation` cancels the database
  observation when its iterator is dropped.
- The store holds **rows**, a projection, not database records. A list row needs eight
  fields; the record has thirty.
- Nothing here is `async` from the view's perspective. The view reads `rows`.

Large lists are windowed: `observeMessages` takes a range and the list requests more as it
scrolls. A 50,000-row mailbox never becomes a 50,000-element array.

## Testing concurrency

- Store and sync tests run under Swift Testing with an in-memory `DatabaseQueue`.
- The fake transport can stall a request indefinitely, which is how cancellation is tested.
- Thread Sanitizer on in CI for the package test targets. Main Thread Checker on for the
  app scheme.
- Any test that needs `sleep` to pass is wrong; use a continuation the fake transport
  resumes.
