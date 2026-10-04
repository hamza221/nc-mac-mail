// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NextcloudMail

/// Selection to rows on screen, at fifty thousand messages.
///
/// The number the brief asks for is "selection to first frame", and this measures everything
/// up to the frame: `show(mailbox:view:filter:)`, the observation starting, the query, the
/// delivery on the main actor and the assignment into `rows` and `sections`. What it cannot
/// measure is SwiftUI drawing the result, which needs a window — see the report for what was
/// not run.
///
/// The ceiling asserted is well above the target, deliberately. A tight bound on a shared
/// machine fails for reasons that have nothing to do with the code, while a loose one still
/// catches the thing worth catching: an index falling out of use, or a window that stopped
/// being a window.
@Suite("Message list performance")
@MainActor
struct MessageListPerformanceTests {
    static let messageCount = 50_000
    static let threadSize = 5

    /// Fifty thousand envelopes through the real write path, in batches of a thousand.
    private static func seedFiftyThousand() async throws -> (mirror: MessageListMirror, seedSeconds: Double) {
        let mirror = try await MessageListMirror.seed()
        let start = DispatchTime.now().uptimeNanoseconds
        var written = 0
        while written < messageCount {
            let batch = min(1000, messageCount - written)
            let first = Int64(written + 1)
            try await mirror.addMessages(
                sentAt: (0..<batch).map { 1_700_000_000 + first + Int64($0) },
                firstRemoteId: first,
                // One thread per five messages, which is what the store's own benchmark uses,
                // so the threaded query is measured against threads rather than singletons.
                threadSize: threadSize,
                seenEvery: 3
            )
            written += batch
        }
        try await mirror.finishEnumerating()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return (mirror, seconds)
    }

    /// Milliseconds from `show` to the first non-empty `rows`.
    private static func timeToFirstRows(_ model: MessageListStore, mailboxId: Int64, view: ListView) async -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        model.show(.mailbox(mailboxId), view: view)
        _ = await waitUntil { !model.rows.isEmpty }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @Test("selection to rows stays inside the budget at fifty thousand messages")
    func selectionToRowsAtFiftyThousand() async throws {
        let seeded = try await Self.seedFiftyThousand()
        let mirror = seeded.mirror
        reportListMeasurement("seeded \(Self.messageCount) envelopes in \(rounded(seeded.seedSeconds)) s")

        let total = try await mirror.store.messages(mailboxId: mirror.mailboxId, view: .flat, range: 0..<1)
        #expect(total.count == 1)

        // A fresh store per measurement: the cost being measured is selecting a mailbox for
        // the first time, which is when nothing is warm.
        let flatModel = MessageListStore(store: mirror.store)
        let flat = await Self.timeToFirstRows(flatModel, mailboxId: mirror.mailboxId, view: .flat)
        #expect(flatModel.rows.count == MessageListStore.initialWindow)
        #expect(flatModel.sections.reduce(0) { $0 + $1.rows.count } == MessageListStore.initialWindow)

        let threadedModel = MessageListStore(store: mirror.store)
        let threaded = await Self.timeToFirstRows(threadedModel, mailboxId: mirror.mailboxId, view: .threaded)
        #expect(threadedModel.rows.count == MessageListStore.initialWindow)
        #expect(try #require(threadedModel.rows.first).threadCount == Self.threadSize)

        let extendStart = DispatchTime.now().uptimeNanoseconds
        flatModel.loadMore()
        let grown = MessageListStore.initialWindow + MessageListStore.windowStep
        _ = await waitUntil { flatModel.rows.count == grown }
        let extend = Double(DispatchTime.now().uptimeNanoseconds - extendStart) / 1_000_000

        reportListMeasurement(
            "selection to \(MessageListStore.initialWindow) flat rows of \(Self.messageCount): \(rounded(flat)) ms")
        reportListMeasurement(
            "selection to \(MessageListStore.initialWindow) threaded rows of \(Self.messageCount): "
                + "\(rounded(threaded)) ms")
        reportListMeasurement("window extended to \(grown) rows: \(rounded(extend)) ms")

        #expect(flat < 1000, "flat took \(rounded(flat)) ms")
        #expect(threaded < 1000, "threaded took \(rounded(threaded)) ms")
        #expect(extend < 1000, "extending took \(rounded(extend)) ms")

        // Twenty more extensions, which is more scrolling than anyone does in one sitting.
        // The list is still an order of magnitude short of the mailbox, which is the whole
        // claim: a fifty-thousand-row mailbox never becomes a fifty-thousand-element array.
        for step in 2...21 {
            flatModel.loadMore()
            let expected = MessageListStore.initialWindow + MessageListStore.windowStep * step
            #expect(await waitUntil { flatModel.rows.count == expected })
        }
        #expect(flatModel.rows.count < Self.messageCount)
        #expect(flatModel.hasMore)
        reportListMeasurement(
            "after 21 extensions the list holds \(flatModel.rows.count) of \(Self.messageCount) rows")
    }
}

/// Writes a measurement where the test log will show it.
///
/// `print` is banned in this repository because a mail body must never reach stdout. A
/// benchmark number is neither a body nor an address and has to be readable in CI output, so
/// it goes to stderr explicitly. The same reasoning as `NCMailStoreTests.reportMeasurement`,
/// which this cannot reuse: it lives in a package's test target.
private func reportListMeasurement(_ text: String) {
    FileHandle.standardError.write(Data(("  [measured] " + text + "\n").utf8))
}

private func rounded(_ value: Double) -> String {
    String(format: "%.3f", value)
}
