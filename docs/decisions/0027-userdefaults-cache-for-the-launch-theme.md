<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0027: Cache the launch theme colour in `UserDefaults`, and still write it to `meta`

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-13, after its brief's "cache the colour in `meta`" turned out to be right
for one of the two problems it was asked to solve, and wrong for the other

## Context

[S-09](../product/user-stories.md#s-09-it-looks-like-the-instance-it-belongs-to-ws-13) and
this workstream's brief both ask for the instance's brand colour to be on screen before the
first frame, on every launch after the first — a returning user must not see the stock
Nextcloud blue and then watch it change. The brief's own suggestion was to cache the colour
in `MailStore`'s `meta` table, which
[`MailStore+Meta.swift`](../../Packages/NCMailStore/Sources/NCMailStore/Queries/MailStore+Meta.swift)
even names as an intended use ("the cached theming colour").

That table's only public accessors are `async`, on purpose:
[concurrency.md](../architecture/concurrency.md) keeps every GRDB access off the main actor,
because a database read on the main actor is how a backfill starts fighting a scroll view for
it. `NextcloudMailApp.init()` runs synchronously, before `WindowGroup` draws anything, and has
no `await` available to it.

Two ways around the synchronous-read problem were available: block the main thread once,
briefly, on a detached task reading `meta` before the run loop starts pumping events; or keep
this one value somewhere that already answers synchronously.

There is a second problem the brief did not name, but
[overview.md](../architecture/overview.md#the-invariant) makes unavoidable once it is looked
for: `ThemeCache.refresh` calls the network. If it also handed the resulting `NCTheme` straight
to a caller to render, that render would be fed by a network response with no database in
between — the one invariant's only exception, quietly introduced. Every other subsystem in this
app writes to the database and lets a view observe it; the theme was on track to be the one
subsystem that didn't.

## Decision

Two mechanisms, for two different problems.

`UserDefaults` holds the colour for the one synchronous read `NextcloudMailApp.init()` needs
before `WindowGroup` draws anything. `ThemeCache.cachedTheme(defaults:)` reads it directly; this
is the only place in the app that turns a cached colour into an `NCTheme` without going through
the database.

`MailStore`'s `meta` table still holds the colour too, exactly as the brief asked, but for a
different reason than "answer synchronously": `ThemeCache.refresh` writes the colour there
instead of handing it back to a caller, and `AppSession` is the one place that turns a `meta`
change into a new `NCTheme`, via `MailStore.observeMetaValue`. The network writes; a
`ValueObservation` renders. Both caches are written together, from the same successful
capabilities call, so they never meaningfully disagree — `UserDefaults` is simply the one a
synchronous `init()` can reach and `meta` is the one everything else, including a future
settings panel, should read instead.

## Consequences

`NextcloudMailApp.init()` stays a plain synchronous function with no concurrency primitives of
its own. The very first launch, with nothing cached yet, still shows the stock palette for one
frame before `ThemeCache.refresh` applies the real one — unavoidable either way, since no
launch can know the server's colour before asking it.

`AppSession.theme` changes only in response to `observeTheme()`'s loop, never as a direct
return value from a network call. That keeps `grep`-ability: nothing in this app *renders*
directly from `NCMailNet` except this one path, and now this one path does not either.

The colour is written twice on every successful refresh — once to `UserDefaults`, once to
`meta` — for two different readers. That is a small amount of duplication to hold in mind, not
a general precedent: a value with only one reader keeps one home.

## Alternatives considered

**Block once on a detached task at launch.** Technically sound — `MailStore`'s GRDB access is
not main-actor work, so a `Task.detached` reading `meta` while `init()` waits on a semaphore
would not deadlock, and the read costs a fraction of a millisecond. Rejected anyway: a
deliberate blocking bridge into `async` code is exactly the kind of code a reviewer has to
stop and prove safe by hand, for a value `UserDefaults` already answers for free.

**Accept the one-frame flash on every launch, not just the first.** Fails the acceptance
criterion directly and is not cheaper to build than the alternative that does not fail it.

**Add a synchronous accessor to `MailStore` for this one key.** Out of scope: `NCMailStore/**`
belongs to WS-03, and widening its public interface to serve one caller's boot sequence is a
request to make in a report, not a change to make directly.

**Hand `ThemeCache.refresh` an `apply: (NCTheme) -> Void` closure and call it directly with the
network result.** The first version of this code did exactly that, and it works — right up
until the question "does anything render straight from a network response" is asked, and the
answer becomes "yes, one thing." Routing the same value through `meta` costs one write and one
`ValueObservation`, and keeps the answer "no" true without a carve-out.

## Revisit when

`MailStore` grows a supported synchronous escape hatch of its own (unlikely, given
[concurrency.md](../architecture/concurrency.md)'s reasoning), or a second value needs the
same "before the first frame" treatment, at which point a small dedicated launch-cache
abstraction is worth naming instead of two ad hoc `UserDefaults` keys.
