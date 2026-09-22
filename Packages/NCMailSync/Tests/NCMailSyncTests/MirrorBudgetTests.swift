// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NCMailSync

/// The counting semaphore behind "two per account, four in total".
///
/// Worth its own tests because every one of its edges is a promise to somebody else's
/// server: over-release and the bound is a suggestion; lose a waiter and the backfill stops
/// with work outstanding and no error.
@Suite("Mirror budget")
struct MirrorBudgetTests {
    @Test("a slot is handed over rather than freed, so a waiter is never overtaken")
    func waitersAreServedInOrder() async throws {
        let budget = MirrorBudget(limit: 1)
        await budget.acquire()
        #expect(await budget.currentInUse == 1)

        let waiting = Task { await budget.acquire() }
        // The waiter cannot proceed while the one slot is taken; releasing hands it over
        // without `inUse` ever dropping, so a caller arriving now would queue behind it.
        await budget.release()
        await waiting.value
        #expect(await budget.currentInUse == 1)

        await budget.release()
        #expect(await budget.currentInUse == 0)
    }

    @Test("cancelling a waiting acquire still grants it, so every acquire has one release")
    func cancellationGrantsRatherThanThrows() async throws {
        let budget = MirrorBudget(limit: 1)
        await budget.acquire()

        let waiting = Task { await budget.acquire() }
        waiting.cancel()
        // Returns rather than hanging: the caller's `defer { release() }` is still correct,
        // and there is no "did I actually get a slot?" branch at any call site.
        await waiting.value
        await budget.release()
        await budget.release()
        #expect(await budget.currentInUse == 0)
    }

    @Test("raising the limit wakes whoever is waiting, which is how a cooldown ends")
    func raisingTheLimitWakesWaiters() async throws {
        let budget = MirrorBudget(limit: 1)
        await budget.acquire()

        let waiting = Task { await budget.acquire() }
        await budget.setLimit(2)
        await waiting.value
        #expect(await budget.currentInUse == 2)
        #expect(await budget.currentLimit == 2)
    }

    @Test("the limit never falls below one, so halving cannot stop the backfill outright")
    func theLimitHasAFloor() async throws {
        let budget = MirrorBudget(limit: 2)
        await budget.setLimit(0)
        #expect(await budget.currentLimit == 1)
    }

    @Test("preempt takes a slot without waiting, which pauses one backfill worker")
    func preemptOverSubscribes() async throws {
        let budget = MirrorBudget(limit: 2)
        await budget.acquire()
        await budget.acquire()
        // Both slots are busy, and the user just opened a message.
        await budget.preempt()
        #expect(await budget.currentInUse == 3)

        // The next worker to finish finds nothing free, so the server still sees two.
        await budget.release()
        #expect(await budget.currentInUse == 2)
    }
}
