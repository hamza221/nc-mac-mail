// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// What a long offline stretch costs, and what waking the drainer does.
///
/// The brief asks for a number on a thousand queued operations after a long offline stretch.
/// It is a measurement, not a threshold: the assertion is a ceiling loose enough to survive a
/// busy machine and tight enough to catch the drain going quadratic.
@Suite("Operation drain at scale", .serialized)
struct OperationDrainScaleTests {
    @Test func aThousandQueuedOperationsDrainInOnePass() async throws {
        let count = 1000
        let fixture = try await QueueTest.make(messages: count)
        await QueueTest.stubEverything(fixture.transport)

        let queuedMilliseconds = try await milliseconds {
            try await fixture.queue.perform(
                .move(messageIds: fixture.messageIds, destinationMailboxId: fixture.archiveId),
                accountId: fixture.accountId
            )
        }
        #expect(try await fixture.rows().count == count)

        let drainedMilliseconds = await milliseconds {
            await fixture.drainer.drain()
        }

        reportQueueMeasurement("queued \(count) operations in one transaction: \(rounded(queuedMilliseconds)) ms")
        reportQueueMeasurement("drained \(count) operations: \(rounded(drainedMilliseconds)) ms")

        #expect(await fixture.transport.sendCount == count)
        #expect(try await fixture.rows().isEmpty)
        #expect(drainedMilliseconds < 10_000, "drained in \(rounded(drainedMilliseconds)) ms")
    }

    @Test func wakingTheDrainerFromAnActionEmptiesTheQueue() async throws {
        let fixture = try await QueueTest.make()
        await QueueTest.stubEverything(fixture.transport)
        // The wiring the app uses: the queue wakes the drainer after the commit, and nothing
        // in between awaits a request.
        let queue = MutationQueue(store: fixture.operations, drainer: fixture.drainer)

        var iterator = fixture.drainer.pendingCount.makeAsyncIterator()
        #expect(await iterator.next()?.queued == 0)

        try await queue.perform(
            .setFlags(messageIds: [fixture.messageIds[0]], flags: ["seen": true]),
            accountId: fixture.accountId
        )

        // Waiting on the stream rather than on a clock: the drain publishes a summary after
        // every operation, so "it finished" is a value rather than a duration.
        while let summary = await iterator.next(), summary.queued > 0 {
            continue
        }
        #expect(await fixture.transport.sendCount == 1)
        #expect(try await fixture.rows().isEmpty)
    }
}

/// Milliseconds spent in `work`.
///
/// `DispatchTime` and not `Date`: this measures an interval, which is the one use of a clock
/// the test rules allow. Nothing asserts on when it happened.
func milliseconds(_ work: () async throws -> Void) async rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try await work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func rounded(_ value: Double) -> String {
    String(format: "%.1f", value)
}
