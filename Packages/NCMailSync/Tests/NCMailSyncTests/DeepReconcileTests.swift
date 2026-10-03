// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

/// The safety net, and the two ways it can be worse than useless: enumerating with the wrong
/// cursor, and deleting from a walk that did not finish.
@Suite("Deep reconcile")
struct DeepReconcileTests {
    @Test("A message missing locally but present on the server is inserted")
    func aHoleIsFilled() async throws {
        let rows = try Recorded.inbox()
        // Three messages the mirror never got — a crash between two pages of the original
        // backfill is exactly this shape.
        let missing = Set([Recorded.id(rows[10]), Recorded.id(rows[40]), Recorded.id(rows[80])])
        let seeded = try await SyncTest.seed(messages: rows.filter { !missing.contains(Recorded.id($0)) })

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(rows))

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        let local = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(Set(local.map(\.remoteId)) == Set(Recorded.ids(rows)))
    }

    @Test("A message deleted outside the window survives the sync and dies in the reconcile")
    func deletionOutsideTheWindowNeedsTheReconcile() async throws {
        // Both halves of the acceptance criterion in one test, because either half alone
        // proves nothing: `vanishedMessages` is `array_diff` over the ids the client sent,
        // so a message the window never claims can never be reported gone.
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let deletedRemotely = Recorded.id(rows[50])
        let localId = try #require(seeded.localByRemote[deletedRemotely])
        let serverRows = rows.filter { Recorded.id($0) != deletedRemotely }

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            // A window of five, so the message at position 50 is far outside it.
            configuration: SyncTest.configuration(clock: TestClock(), windowSize: 5)
        )
        let claimed = Array(rows.prefix(5))
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: 5),
            with: try Recorded.syncResponse(changed: claimed, total: serverRows.count, unread: 23)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(serverRows))

        await scheduler.syncNow(mailboxId: seeded.inboxId)
        #expect(
            try await seeded.store.message(id: localId) != nil,
            "the incremental loop cannot see a deletion outside the window; that is the accepted trade"
        )

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)
        #expect(try await seeded.store.message(id: localId) == nil, "and the reconcile is what finds it")
        #expect(await scheduler.metrics.messagesDeleted == 1)
    }

    @Test("Pagination sends oldest dateInt + 1, and the walk reaches every message")
    func theCursorIsOnePastTheOldest() async throws {
        // The blind spot this test exists for: ids 44 and 45 share a `dateInt`, the cursor
        // comparison is strict, and a page boundary between them makes the second
        // unreachable. Serving the pages from a model of the server's own `<` rather than
        // from a fixed list is what makes a wrong cursor fail here rather than pass.
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: [])
        let pageSize = 20

        var pages: [StubResponse] = []
        var cursors: [Int64?] = []
        var cursor: Int64?
        while true {
            let page = Recorded.page(rows, cursor: cursor, limit: pageSize)
            cursors.append(cursor)
            pages.append(try Recorded.page(page))
            if page.count < pageSize { break }
            let oldest = try #require(page.map(Recorded.dateInt).min())
            cursor = oldest + 1
        }

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock(), pageSize: pageSize)
        )
        await transport.stubSequence(MirrorTest.messagesRoute(mailboxId: 5), pages)

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        let asked = await transport.requestURLs.filter { $0.contains("mailboxId=5") }
        let sent = asked.map { url -> Int64? in
            guard let range = url.range(of: "cursor=") else { return nil }
            return Int64(url[range.upperBound...].prefix { $0.isNumber })
        }
        #expect(sent == cursors, "every page after the first asks for one past the oldest it saw")

        let local = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(Set(local.map(\.remoteId)) == Set(Recorded.ids(rows)))
        #expect(local.map(\.remoteId).contains(45), "the message a plain oldest-dateInt cursor would skip")
    }

    @Test("A walk that did not finish deletes nothing")
    func anIncompleteWalkDeletesNothing() async throws {
        // The one way this routine could destroy a mirror instead of repairing one. The
        // second page fails, so the enumeration knows about the first twenty ids and nothing
        // else; treating that as the whole truth would remove seventy-five messages.
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let pageSize = 20

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock(), pageSize: pageSize)
        )
        await transport.stubSequence(
            MirrorTest.messagesRoute(mailboxId: 5),
            [try Recorded.page(Array(rows.prefix(pageSize))), .status(500)]
        )

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        let local = try await seeded.store.messages(mailboxId: seeded.inboxId, view: .flat, range: 0..<500)
        #expect(local.count == rows.count)
        #expect(await scheduler.metrics.messagesDeleted == 0)
        #expect(await scheduler.metrics.mailboxes[seeded.inboxId]?.consecutiveFailures == 1)
    }

    @Test("Bodies that gave up after three tries are re-queued")
    func failedBodiesAreRetried() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let brokenId = try #require(seeded.localByRemote[Recorded.id(rows[7])])
        try await seeded.store.setBodyState(.failed, messageIds: [brokenId])

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(rows))

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        let record = try #require(try await seeded.store.message(id: brokenId))
        #expect(record.bodyState == .missing, "back in the queue, for stage 2 to pick up")
    }

    @Test("A refreshed envelope never tells the mirror it has lost a body")
    func aReconcileKeepsStoredBodies() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let withBody = try #require(seeded.localByRemote[Recorded.id(rows[2])])
        try await seeded.store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, hasHtmlBody: false, plainBody: "already mirrored"),
            for: withBody
        )

        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(rows))

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        let stored = try #require(try await seeded.store.body(messageId: withBody))
        #expect(stored.body.plainBody == "already mirrored")
        let record = try #require(try await seeded.store.message(id: withBody))
        #expect(record.bodyState == .present, "bodies are immutable in IMAP; only flags and tags change")
    }

    @Test("The weekly reconcile leaves the mailbox the user is scrolling alone")
    func theWeeklyPassSkipsTheSelectedMailbox() async throws {
        let seeded = try await SyncTest.seed(messages: try Recorded.inbox())
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock())
        )
        for mailbox in [3, 4, 5, 6, 7] {
            await transport.stub(
                MirrorTest.messagesRoute(mailboxId: mailbox),
                with: try .fixture("messages-inbox-page2.json")
            )
        }
        await scheduler.setSelectedMailbox(seeded.inboxId)

        await scheduler.reconcilePass(mailboxIds: nil, skipSelected: true)

        let asked = await transport.requestURLs.filter { $0.contains("/messages?") }
        #expect(!asked.contains { $0.contains("mailboxId=5") })
        #expect(asked.count == 4, "the other four mirrored mailboxes were walked")

        // Asked for explicitly, it runs regardless: Settings › Check for missing messages is
        // the user saying they want it now.
        await scheduler.deepReconcile(mailboxId: seeded.inboxId)
        let afterwards = await transport.requestURLs.filter { $0.contains("mailboxId=5") }
        #expect(!afterwards.isEmpty)
    }

    @Test("The reconcile stamps when it last ran, so the weekly timer survives a relaunch")
    func theLastRunIsPersisted() async throws {
        let seeded = try await SyncTest.seed(messages: try Recorded.inbox())
        let clock = TestClock()
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: clock)
        )
        await transport.stub(MirrorTest.messagesRoute(mailboxId: 5), with: try Recorded.page(try Recorded.inbox()))

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        #expect(await scheduler.metrics.lastDeepReconcileAt == clock.now)
        let stored = try await seeded.store.metaValue(forKey: "sync.lastDeepReconcile.\(seeded.accountId)")
        #expect(stored == String(clock.now))
    }
}

/// What an account whose server-side sort order is oldest-first can and cannot have.
@Suite("Oldest-first sort order")
struct OldestFirstTests {
    @Test("The tail scan is disabled rather than run in the wrong direction")
    func theTailScanIsSkipped() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            // Measured against the live server: with this preference set, page one of
            // `GET /messages` is the *oldest* hundred and `cursor` becomes a lower bound, so
            // a scan "from the newest" cannot be expressed at all. ADR-0036.
            sortOrder: "oldest"
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: 5),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        #expect(await scheduler.metrics.tailScanUnavailable)
        let asked = await transport.requestURLs.filter { $0.contains("/messages?") }
        #expect(asked.isEmpty, "no page was fetched, rather than the oldest hundred fetched forever")
        #expect(await scheduler.metrics.mailboxes[seeded.inboxId]?.lastSuccessAt != nil)
    }

    @Test("The sort order reaches the sync request body, because that one is a parameter")
    func theSyncRequestCarriesTheSortOrder() async throws {
        let rows = try Recorded.inbox()
        let seeded = try await SyncTest.seed(messages: rows)
        let transport = FakeTransport()
        let scheduler = try await SyncTest.scheduler(
            seeded,
            transport: transport,
            configuration: SyncTest.configuration(clock: TestClock()),
            sortOrder: "oldest"
        )
        await transport.stub(
            MirrorTest.syncRoute(mailboxId: 5),
            with: try Recorded.syncResponse(changed: rows, total: rows.count, unread: 23)
        )

        await scheduler.syncNow(mailboxId: seeded.inboxId)

        let body = try #require(
            await transport.requests.first { $0.url?.path.hasSuffix("/mailboxes/5/sync") == true }?.httpBody
        )
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["sortOrder"] as? String == "oldest")
        #expect(sent["init"] as? Bool == false)
        #expect((sent["ids"] as? [Any])?.count == 95)
    }
}
