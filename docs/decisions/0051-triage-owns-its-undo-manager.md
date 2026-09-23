<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0051: Triage owns its `UndoManager`, and undo is the inverse operation

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-10

## Context

The [WS-10 brief](../delivery/briefs/WS-10-triage.md) asks for "undo via the system
`UndoManager` for the last action, mapped to its inverse operation", and says the queue
already makes it cheap. Two things had to be settled to write it.

**Which manager.** `@Environment(\.undoManager)` is supplied by a document-backed scene. The
app is a plain `WindowGroup`, so that value can be nil, and an undo stack that exists or does
not depending on how the shell was assembled is not a feature.

**Where the inverse comes from.** The queue already records a `before` snapshot in
`payloadJSON`, which is what makes **Discard** able to revert a failed operation. It is
`internal` to `NCMailSync` and it is reached by operation id, neither of which an action
layer has. Reading the messages before acting costs one query the action was making anyway.

`UndoManager` and `async` also do not fit together on their own. The handler runs
synchronously inside `undo()`, and a registration made after an `await` lands on the undo
stack rather than the redo one, which silently breaks redo.

## Decision

`MessageActions` owns an `UndoManager`, and `MailCommands` replaces the standard Edit ▸ Undo
group with items that drive it. `⌘Z` and `⌘⇧Z` keep their keys.

An undo is **not a rollback**. It is the inverse action, queued through `MutationQueue` like
any other, so it works offline and the server is told about both halves. A move records each
message's own origin folder, so undoing a move that gathered messages from three folders puts
each one back in its own. A flag change records each message's own previous value, so undoing
a star on a mixed selection gives back the mix.

Redo is registered **synchronously**, inside the handler `UndoManager` calls during `undo()`,
before the database work starts in a `Task`. The registration only has to describe what redo
would do, and that is already known, so it does not need the write to have finished.

## Consequences

- `⌘Z` after an accidental archive works with the network off, which is the case the brief
  names.
- Undoing leaves **two** queue rows rather than none: the archive and the move back. That is
  correct. The drain may already have told the server about the first, and the collapse rule
  in [offline-queue.md](../architecture/offline-queue.md) folds the pair when it has not.
- An erase — `delete` of a message already in trash — registers no undo at all. The row is
  gone and nothing restores it, which is the same exception **Discard** has.
- An action that queued nothing, such as archive on an account with no archive folder, leaves
  the undo stack alone. There is nothing to take back.

## Alternatives considered

**Reach into the queue's `before` snapshot.** It is the same information, behind an
`internal` type, reached by an id the caller does not have. It would need a new public method
on `MutationQueue` in another workstream's module to save one query.

**Roll back locally without queueing.** The screen would go back and the server would not,
which is precisely the state [ADR-0005](0005-offline-mutation-queue.md) exists to prevent.

**A private undo stack instead of `UndoManager`.** It would drop `⌘Z`'s action name in the
menu ("Undo Archive"), its coalescing, and everything a macOS user expects of the Edit menu.

## Revisit when

The app becomes document-backed, or a scene starts supplying a real
`@Environment(\.undoManager)`.
