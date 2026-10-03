// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation

/// A counting semaphore that suspends instead of blocking, so the mirror can promise the
/// server a number and keep it.
///
/// `local-mirror.md` makes bounded concurrency rule 1 of four, and the bound is two figures
/// rather than one: two body fetches per account *and* four across every account. A task
/// group gives the first for free; the second needs something the accounts share, which is
/// what ``shared`` is. An actor rather than a lock, per
/// `docs/architecture/concurrency.md` rule 3.
///
/// Every ``acquire()`` is matched by exactly one ``release()``, including the cancelled
/// case: a waiter whose task is cancelled is granted its slot rather than thrown out, so
/// the caller's `defer { release() }` stays correct and there is no "did I get one?" branch
/// at any call site.
actor MirrorBudget {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var limit: Int
    private var inUse = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// The four-in-total cap from `networking.md#concurrency-budget`. One per process, so
    /// three accounts backfilling at once still only ask the server for four bodies.
    static let shared = MirrorBudget(limit: 4)

    var currentLimit: Int { limit }
    var currentInUse: Int { inUse }

    func acquire() async {
        // Already cancelled: take the fast path rather than register a waiter that the
        // cancellation handler may have already run past.
        if inUse < limit || Task.isCancelled {
            inUse += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Runs synchronously while this actor is held, so the waiter is registered
                // before any task the cancellation handler spawns can look for it.
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.grant(id) }
        }
    }

    /// Takes a slot without waiting, over-subscribing the budget by one until it is
    /// released. This is how an interactive fetch preempts the backfill: the user's message
    /// starts immediately, and the next worker to finish finds no slot free and waits, so
    /// one backfill worker is paused for the duration rather than the server seeing three.
    func preempt() {
        inUse += 1
    }

    func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            // Handed straight over: `inUse` does not move, so a released slot cannot be
            // taken by a newly arriving caller ahead of someone who has been waiting.
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Halves or restores the budget. Rule 3: a 429 or a 503 halves body concurrency for
    /// ten minutes, and raising it again must wake whoever is waiting.
    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        while inUse < limit, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func grant(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        inUse += 1
        waiter.continuation.resume()
    }
}
