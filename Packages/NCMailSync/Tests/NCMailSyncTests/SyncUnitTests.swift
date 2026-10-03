// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailStore
import Testing

@testable import NCMailSync

/// The parts of the sync engine that are functions rather than loops. Every one of these
/// runs without a store, a socket or a clock.
@Suite("Sync cadence")
struct SyncCadenceTests {
    private let cadence = SyncCadence(configuration: SyncConfiguration())

    private func mailbox(
        _ id: Int64,
        isInbox: Bool = false,
        lastSuccessAt: Int64? = nil,
        nextAttemptAt: Int64? = nil
    ) -> SyncCadence.MailboxState {
        SyncCadence.MailboxState(
            id: id,
            isInbox: isInbox,
            lastSuccessAt: lastSuccessAt,
            nextAttemptAt: nextAttemptAt
        )
    }

    @Test("Every inbox syncs at the foreground interval whether or not it is on screen")
    func inboxUsesTheForegroundInterval() {
        #expect(cadence.interval(for: mailbox(1, isInbox: true), selected: nil) == 120)
        #expect(cadence.interval(for: mailbox(2), selected: 2) == 120)
        #expect(cadence.interval(for: mailbox(3), selected: 2) == 600)
    }

    @Test("A mailbox synced inside its interval is not due")
    func intervalIsRespected() {
        let now: Int64 = 1_000_000
        let states = [
            mailbox(1, isInbox: true, lastSuccessAt: now - 60),
            mailbox(2, lastSuccessAt: now - 300),
            mailbox(3, lastSuccessAt: now - 700),
        ]
        #expect(cadence.due(at: now, mailboxes: states, selected: nil) == [3])
    }

    @Test("A mailbox that has never synced is due")
    func neverSyncedIsDue() {
        let states = [mailbox(1), mailbox(2, lastSuccessAt: 999_999)]
        #expect(cadence.due(at: 1_000_000, mailboxes: states, selected: nil) == [1])
    }

    @Test("A failure backoff holds a mailbox back even once its interval has elapsed")
    func backoffOverridesTheInterval() {
        let now: Int64 = 1_000_000
        let states = [
            mailbox(1, lastSuccessAt: now - 700, nextAttemptAt: now + 30),
            mailbox(2, lastSuccessAt: now - 700),
        ]
        #expect(cadence.due(at: now, mailboxes: states, selected: nil) == [2])
        // Equally neglected once the backoff lapses, so the tie breaks on id and both run.
        #expect(cadence.due(at: now + 30, mailboxes: states, selected: nil) == [1, 2])
    }

    @Test("The selected mailbox goes first, then inboxes, then the most neglected")
    func orderIsSelectedThenInboxThenNeglected() {
        let now: Int64 = 1_000_000
        let states = [
            mailbox(10, lastSuccessAt: now - 5_000),
            mailbox(11, lastSuccessAt: now - 9_000),
            mailbox(12, isInbox: true, lastSuccessAt: now - 200),
            mailbox(13, lastSuccessAt: now - 1_000),
        ]
        #expect(cadence.due(at: now, mailboxes: states, selected: 13) == [13, 12, 11, 10])
    }

    @Test("Round-robin: the three least recently synced go next, and next time the others do")
    func roundRobinRotates() {
        let now: Int64 = 1_000_000
        var last: [Int64: Int64] = [1: now - 700, 2: now - 800, 3: now - 900, 4: now - 1_000, 5: now - 1_100]
        func states() -> [SyncCadence.MailboxState] {
            last.keys.sorted().map { mailbox($0, lastSuccessAt: last[$0]) }
        }
        let first = Array(cadence.due(at: now, mailboxes: states(), selected: nil).prefix(3))
        #expect(first == [5, 4, 3])
        for id in first { last[id] = now }
        let second = Array(cadence.due(at: now, mailboxes: states(), selected: nil).prefix(3))
        #expect(second == [2, 1])
    }
}

@Suite("Sync conflicts")
struct SyncConflictTests {
    private func write(seen: Bool, flagged: Bool) -> EnvelopeWrite {
        var flags = NCMailStore.MessageFlags()
        flags.isSeen = seen
        flags.isFlagged = flagged
        return EnvelopeWrite(remoteId: 7, mailboxId: 1, accountId: 1, sentAt: 10, syncedAt: 10, flags: flags)
    }

    @Test("With nothing queued the server wins every field")
    func serverWinsWithNoIntent() {
        let result = SyncConflicts.apply([write(seen: false, flagged: false)], localIds: [42], intents: [:])
        #expect(result[0].isSeen == false)
    }

    @Test("A queued field survives the sync; every other field does not")
    func localWinsForTheQueuedFieldOnly() {
        let intent = PendingIntent(messageId: 42, flags: ["seen": true])
        let result = SyncConflicts.apply(
            [write(seen: false, flagged: true)],
            localIds: [42],
            intents: [42: intent]
        )
        #expect(result[0].isSeen == true, "the user marked it read and the server has not heard")
        #expect(result[0].isFlagged == true, "flagged is not queued, so the server's value stands")
    }

    @Test("An intent for another message leaves this one alone")
    func intentsAreKeyedByMessage() {
        let intent = PendingIntent(messageId: 99, flags: ["seen": true])
        let result = SyncConflicts.apply(
            [write(seen: false, flagged: false)],
            localIds: [42],
            intents: [99: intent]
        )
        #expect(result[0].isSeen == false)
    }

    @Test("A new message has no local id, so it can carry no intent")
    func newMessagesAreNeverMasked() {
        let intent = PendingIntent(messageId: 42, flags: ["seen": true])
        let result = SyncConflicts.apply(
            [write(seen: false, flagged: false)],
            localIds: [nil],
            intents: [42: intent]
        )
        #expect(result[0].isSeen == false)
    }

    @Test("Every flag the setter accepts and the store has a column for is masked")
    func everyMaskableFlag() {
        let intent = PendingIntent(
            messageId: 1,
            flags: ["seen": true, "flagged": true, "junk": true, "important": true, "answered": true]
        )
        let masked = SyncConflicts.apply(intent, to: write(seen: false, flagged: false))
        #expect(masked.isSeen && masked.isFlagged && masked.isJunk && masked.isImportant && masked.isAnswered)
    }

    @Test("An IMAP keyword the store has no column for is ignored rather than fatal")
    func unknownKeysAreIgnored() {
        let intent = PendingIntent(messageId: 1, flags: ["$sillylabel": true])
        let masked = SyncConflicts.apply(intent, to: write(seen: false, flagged: false))
        #expect(masked.isSeen == false)
    }
}

/// The trap that costs a message and shows nothing.
///
/// `GET /messages`'s cursor comparison is strict and `dateInt` is not unique. Both halves are
/// measured against the live server and recorded in `api-payloads.md`; this suite proves the
/// client's arithmetic against a model of the server's comparison rather than against a
/// second copy of the client's.
@Suite("Enumeration cursor")
struct EnumerationCursorTests {
    @Test("The live inbox really does have two messages sharing a dateInt")
    func theRecordedPairExists() throws {
        let rows = try Recorded.inbox()
        let pair = try Recorded.sharedDateIntPair(rows)
        #expect(Recorded.id(pair.first) != Recorded.id(pair.second))
        #expect(Recorded.dateInt(pair.first) == Recorded.dateInt(pair.second))
    }

    @Test("The plain oldest dateInt loses the second message of the pair; oldest + 1 keeps it")
    func offByOneLosesAMessage() throws {
        let rows = try Recorded.inbox()
        let pair = try Recorded.sharedDateIntPair(rows)
        let (first, second) = (Recorded.id(pair.first), Recorded.id(pair.second))
        // The page that ends on the first of the pair, which is where the boundary falls.
        let boundary = try #require(rows.firstIndex { Recorded.id($0) == first })
        let page = Array(rows.prefix(boundary + 1))
        let oldest = try #require(page.map(Recorded.dateInt).min())

        let naive = Recorded.page(rows, cursor: oldest, limit: 100)
        #expect(!Recorded.ids(naive).contains(second), "this is the bug: the boundary message is unreachable")

        let corrected = try #require(
            SyncScheduler.nextCursor(
                after: try envelopes(page),
                sortOrder: .newest
            ))
        #expect(corrected == oldest + 1)
        let fixed = Recorded.page(rows, cursor: corrected, limit: 100)
        #expect(Recorded.ids(fixed).contains(second), "oldest + 1 re-reads the boundary and finds its twin")
        #expect(Recorded.ids(fixed).contains(first), "and repeats the boundary message, whose upsert is a no-op")
    }

    @Test("Under an oldest-first sort order the cursor is a lower bound, so the ±1 flips")
    func oldestFirstFlipsTheCursor() throws {
        let rows = try Recorded.inbox()
        let page = Array(rows.suffix(10))
        let newest = try #require(page.map(Recorded.dateInt).max())
        let cursor = try #require(SyncScheduler.nextCursor(after: try envelopes(page), sortOrder: .oldest))
        #expect(cursor == newest - 1)
    }

    @Test("An empty page yields no cursor, so the walk stops rather than asking again")
    func emptyPageEndsTheWalk() throws {
        #expect(SyncScheduler.nextCursor(after: [], sortOrder: .newest) == nil)
    }

    private func envelopes(_ rows: [[String: Any]]) throws -> [RawBacked<Envelope>] {
        try JSONDecoder().decode([RawBacked<Envelope>].self, from: try Recorded.data(rows))
    }
}
