// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import Testing

@testable import NCMailSync

/// The four collapsing rules from `offline-queue.md`, each one on its own.
///
/// No store and no clock: ``OperationCollapse/collapse(_:)`` is a function over rows, which
/// is what lets these read as a list of rows and an expected answer.
@Suite("Operation collapsing")
struct OperationCollapseTests {
    /// A queue row, with only the fields the rules look at.
    private func row(
        _ id: Int64,
        _ kind: OperationKind,
        message: Int64? = 1,
        thread: String? = nil,
        flags: [String: Bool] = [:],
        destination: Int64? = nil,
        before: OperationSnapshot = OperationSnapshot(),
        attempts: Int = 0
    ) throws -> PendingOperationRecord {
        var payload = OperationPayload(flags: flags, destinationMailboxId: destination)
        payload.before = before
        return PendingOperationRecord(
            id: id,
            kind: kind.rawValue,
            accountId: 1,
            messageId: message,
            threadRootId: thread,
            mailboxId: destination,
            payloadJSON: try payload.encoded(),
            createdAt: 0,
            baseSyncedAt: 0,
            attempts: attempts
        )
    }

    @Test func consecutiveFlagChangesMergeAndLaterKeysWin() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, flags: ["flagged": true]),
            try row(2, .setFlags, flags: ["flagged": false]),
            try row(3, .setFlags, flags: ["flagged": true, "seen": true]),
        ])

        #expect(work.count == 1)
        #expect(work[0].payload.flags == ["flagged": true, "seen": true])
        #expect(work[0].absorbedIds == [1, 2, 3])
    }

    @Test func aMoveFollowedByAMoveKeepsTheLastDestination() throws {
        let work = OperationCollapse.collapse([
            try row(1, .move, destination: 10),
            try row(2, .move, destination: 20),
        ])

        #expect(work.count == 1)
        #expect(work[0].payload.destinationMailboxId == 20)
        #expect(work[0].absorbedIds == [1, 2])
    }

    @Test func anythingFollowedByADeleteBecomesTheDelete() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, flags: ["seen": true]),
            try row(2, .move, destination: 10),
            try row(3, .delete),
        ])

        #expect(work.count == 1)
        #expect(work[0].kind == .delete)
        // The flag change and the move still have rows to delete, so the delete inherits
        // their ids along with their pointlessness.
        #expect(work[0].absorbedIds == [1, 2, 3])
    }

    @Test func aFlagChangeAndAMoveAreTwoRequestsInQueueOrder() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, flags: ["junk": true]),
            try row(2, .move, destination: 10),
        ])

        #expect(work.map(\.kind) == [.setFlags, .move])
    }

    @Test func differentMessagesNeverCollapseAndKeepTheirOrder() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, message: 1, flags: ["seen": true]),
            try row(2, .setFlags, message: 2, flags: ["seen": true]),
            try row(3, .setFlags, message: 1, flags: ["flagged": true]),
            try row(4, .delete, message: 2),
        ])

        #expect(work.count == 2)
        #expect(work.map(\.id) == [1, 2])
        #expect(work[0].messageId == 1)
        #expect(work[0].payload.flags == ["seen": true, "flagged": true])
        #expect(work[1].kind == .delete)
    }

    @Test func aThreadOperationNeverCollapsesIntoAMessageOperation() throws {
        let work = OperationCollapse.collapse([
            try row(1, .move, message: 1, destination: 10),
            try row(2, .moveThread, message: 1, thread: "t-1", destination: 20),
        ])

        #expect(work.count == 2)
        #expect(work.map(\.kind) == [.move, .moveThread])
    }

    @Test func aFoldRevertsToTheStateBeforeItsOldestRow() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, flags: ["flagged": true], before: snapshot(["flagged": false])),
            try row(2, .setFlags, flags: ["flagged": false], before: snapshot(["flagged": true])),
            try row(3, .setFlags, flags: ["flagged": true], before: snapshot(["flagged": false])),
        ])

        // Not `true`, which is what the row immediately before the last one held. Star,
        // unstar, star started from unstarred, and that is where Discard has to land.
        #expect(work[0].payload.before.flags == ["flagged": false])
    }

    @Test func theHighestAttemptCountOfAFoldIsWhatDecidesVisibility() throws {
        let work = OperationCollapse.collapse([
            try row(1, .setFlags, flags: ["seen": true], attempts: 7),
            try row(2, .setFlags, flags: ["seen": false], attempts: 0),
        ])

        #expect(work[0].attempts == 7)
    }

    private func snapshot(_ flags: [String: Bool]) -> OperationSnapshot {
        OperationSnapshot(messageIds: [1], flags: flags)
    }
}
