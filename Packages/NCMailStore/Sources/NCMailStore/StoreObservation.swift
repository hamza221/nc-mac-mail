// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A live query: a value now, and another one every time the rows behind it change.
///
/// This is the store's own sequence rather than GRDB's `AsyncValueObservation`, and the
/// reason is the dependency rule in
/// [overview.md](../../../../docs/architecture/overview.md#modules). Returning GRDB's type
/// made every caller depend on GRDB's symbols — including the app target, which names GRDB
/// nowhere — and that is a rule broken and a link that fails as soon as a second target
/// makes Xcode build the package products as dynamic frameworks
/// ([ADR-0029](../../../../docs/decisions/0029-app-test-target-borrows-its-modules-from-the-host.md)).
///
/// Neither this type nor its iterator names a GRDB type in a stored property, so a client
/// resolves both out of `NCMailStore` alone. The implementation is the one GRDB's
/// `values(in:scheduling:)` uses, an observation started per iterator feeding an
/// `AsyncThrowingStream`, with two differences:
///
/// - `MailStore.observation(_:)` does not deliver a value equal to the last one it
///   delivered. A commit to a table the query reads is not a change to what it returns.
/// - At most one value waits for the consumer, the newest. Every value is a whole snapshot,
///   so the ones it superseded carry nothing it lacks, and a slow consumer does not pile up
///   one copy per commit.
///
/// - Values arrive on the main actor. `MailStore.observation(_:)` schedules there, so a
///   `@MainActor @Observable` store can assign straight from the loop.
/// - The observation lives exactly as long as the iteration. Dropping the iterator —
///   which is what cancelling or replacing the `Task` around a `for await` does —
///   terminates the stream, and terminating the stream cancels the observation. That is
///   what makes "replace the observation, do not add to it"
///   ([concurrency.md](../../../../docs/architecture/concurrency.md#observation-precisely))
///   true rather than merely intended.
/// - The sequence is multi-pass and lazy: nothing starts until something iterates, and two
///   iterations are two independent observations.
public struct StoreObservation<Element: Sendable>: AsyncSequence, Sendable {
    /// Starts one observation against `continuation`, and arranges for the continuation's
    /// termination to stop it again.
    typealias Start = @Sendable (AsyncThrowingStream<Element, any Error>.Continuation) -> Void

    private let start: Start

    init(start: @escaping Start) {
        self.start = start
    }

    public func makeAsyncIterator() -> AsyncIterator {
        // `.bufferingNewest(1)`: every value is a complete snapshot of the query, so one that
        // a newer value superseded before the consumer got to it carries nothing the newer
        // one lacks. GRDB's own default, `.unbounded`, kept one full copy per commit for a
        // consumer that was slow for a while — a message view re-rendering a large body held
        // a body per backfill commit.
        let stream = AsyncThrowingStream(Element.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            start(continuation)
        }
        return AsyncIterator(base: stream.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        /// The only stored property, and deliberately a standard-library type: it is what
        /// keeps the whole iterator's layout free of anything a client would have to link
        /// GRDB to lay out.
        var base: AsyncThrowingStream<Element, any Error>.AsyncIterator

        /// Nil once the iterating task is cancelled, even with a value already buffered.
        ///
        /// `AsyncThrowingStream` hands out what it buffered before reporting the end, so a
        /// cancelled `for await` could still assign one stale snapshot after its replacement
        /// had assigned a fresh one: a search footer counting the previous scope's mail.
        public mutating func next() async throws -> Element? {
            guard !Task.isCancelled else { return nil }
            let value = try await base.next()
            return Task.isCancelled ? nil : value
        }
    }
}
