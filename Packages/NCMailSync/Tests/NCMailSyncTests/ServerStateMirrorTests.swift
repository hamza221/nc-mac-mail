// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailFixtures
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Synchronization
import Testing

@testable import NCMailSync

/// WS-21: every piece of server state v2 shows lands in the store, a failed request never
/// takes a row away, and offline nothing is asked at all.
@Suite("Server-state mirror")
struct ServerStateMirrorTests {
    // MARK: - Every kind

    @Test("one refresh mirrors every kind from the recordings")
    func refreshMirrorsEveryKind() async throws {
        let setup = try await ServerStateTest.store()
        let transport = FakeTransport()
        try await ServerStateTest.stubEverything(transport)
        let mirror = try ServerStateTest.mirror(setup, transport: transport)

        let report = await mirror.refresh(trigger: .launch)

        #expect(report.failed.isEmpty, "\(report.failed)")
        #expect(report.refreshed == Set(ServerStateKind.allCases))
        let snapshot = try await ServerStateTest.snapshot(setup)

        // Account signature and alias signatures, from the payload rather than a blank.
        let accounts = try #require(try ServerStateTest.json("accounts-signatures.json") as? [[String: Any]])
        let account = try #require(accounts.first)
        let signature = try #require(account["signature"] as? String)
        #expect(snapshot.signature == signature)
        let aliases = try #require(account["aliases"] as? [[String: Any]])
        #expect(
            snapshot.aliases.map(\.remoteId).sorted()
                == aliases.compactMap { ($0["id"] as? NSNumber)?.int64Value }.sorted())
        #expect(
            snapshot.aliases.contains { $0.signature?.isEmpty == false },
            "the scratch alias was recorded with a signature")

        // Quota: a ready row keyed by the local account id.
        let quota = try ServerResultPayload(payloadJSON: try #require(snapshot.quota).payloadJSON)
        #expect(quota == .ready(.object(["usage": .int(0), "limit": .int(0)])))

        #expect(snapshot.delegations.map(\.userId) == ["alice"])

        // Sieve is off in this recording: a row that says so, and no Sieve request.
        #expect(snapshot.sieve?.sieveEnabled == false)
        #expect(await transport.requestPaths.allSatisfy { !$0.contains("/sieve/") && !$0.contains("/filter/") })

        // Quick actions with their steps, in order.
        let actions = try #require(
            (try ServerStateTest.json("quick-actions.json") as? [String: Any])?["data"] as? [[String: Any]]
        )
        let mine = actions.filter { ($0["accountId"] as? NSNumber)?.intValue == ServerStateTest.remoteAccountId }
        #expect(snapshot.quickActions.count == mine.count)
        let stepCount = mine.reduce(0) { $0 + (($1["actionSteps"] as? [Any])?.count ?? 0) }
        #expect(snapshot.quickActionSteps.count == stepCount)

        #expect(snapshot.preferences["sort-order"] == .some("newest"))

        // Block 8 is both mine and shared with a group I am in: one row, the own one.
        #expect(snapshot.textBlocks.count == 1)
        #expect(snapshot.textBlocks.first?.isShared == false)
        #expect(snapshot.textBlockShares.map(\.shareWith) == ["admin"])

        // Individual and domain entries, kept apart by `type`.
        #expect(Set(snapshot.trustedSenders.map(\.type)) == ["individual", "domain"])
        #expect(snapshot.internalAddresses.map(\.type) == ["domain"])

        let certificate = try #require(snapshot.smimeCertificates.first)
        #expect(certificate.canSign && certificate.canEncrypt && certificate.hasPrivateKey)

        let outboxEntries = try #require(
            ((try ServerStateTest.json("outbox.json") as? [String: Any])?["data"] as? [String: Any])?["messages"]
                as? [[String: Any]]
        )
        #expect(snapshot.outbox.count == outboxEntries.count)
        #expect(snapshot.outbox.first?.recipientsJSON.contains("\"kind\":\"to\"") == true)
    }

    @Test("an account with Sieve on gets its script, filters and out-of-office mirrored")
    func sieveWhenEnabled() async throws {
        let setup = try await ServerStateTest.store()
        let transport = FakeTransport()
        try await ServerStateTest.stubEverything(transport, sieveEnabled: true)
        let mirror = try ServerStateTest.mirror(setup, transport: transport)

        let report = await mirror.refresh(trigger: .settingsOpened)

        #expect(report.refreshed.contains(.sieve), "\(report.failed)")
        let sieve = try #require(try await setup.store.sieveState(accountId: setup.accountId))
        #expect(sieve.sieveEnabled)
        let account = try #require((try ServerStateTest.json("accounts-sieve-enabled.json") as? [[String: Any]])?.first)
        #expect(sieve.sieveHost == account["sieveHost"] as? String)
        #expect(sieve.sievePort == (account["sievePort"] as? NSNumber)?.intValue)
        let active = try #require(try ServerStateTest.json("sieve-active-enabled.json") as? [String: Any])
        #expect(sieve.script == active["script"] as? String)
        // The recorded account has no filters and never configured out-of-office.
        #expect(sieve.filtersJSON == "[]")
        #expect(sieve.outOfOfficeJSON == nil)
    }

    // MARK: - Failure paths

    /// For each kind: a first refresh mirrors everything; a second one where that kind's
    /// route fails reports the kind failed and leaves its rows exactly as they were, while
    /// every other kind refreshes.
    @Test("a failing kind keeps its last mirrored rows", arguments: ServerStateKind.allCases)
    func failingKindKeepsRows(kind: ServerStateKind) async throws {
        let setup = try await ServerStateTest.store()
        let sieveEnabled = kind == .sieve
        let good = FakeTransport()
        try await ServerStateTest.stubEverything(good, sieveEnabled: sieveEnabled)
        _ = try await ServerStateTest.mirror(setup, transport: good).refresh(trigger: .launch)
        let before = try await ServerStateTest.snapshot(setup)

        let failing = FakeTransport()
        // Registered first, so it wins over the success stub for the same route.
        await failing.stub(try #require(ServerStateTest.routes(of: kind).first), with: .status(500))
        try await ServerStateTest.stubEverything(failing, sieveEnabled: sieveEnabled)
        let report = try await ServerStateTest.mirror(setup, transport: failing).refresh(trigger: .launch)

        #expect(report.failed.keys.sorted() == [kind])
        #expect(report.refreshed == Set(ServerStateKind.allCases).subtracting([kind]))
        let after = try await ServerStateTest.snapshot(setup)
        #expect(after.same(kind, as: before), "\(kind) rows changed after a failed refresh")
    }

    @Test("airplane mode: every request failing keeps every mirrored row visible")
    func everythingFailingKeepsEverything() async throws {
        let setup = try await ServerStateTest.store()
        let good = FakeTransport()
        try await ServerStateTest.stubEverything(good)
        _ = try await ServerStateTest.mirror(setup, transport: good).refresh(trigger: .launch)
        let before = try await ServerStateTest.snapshot(setup)

        // What a dropped connection looks like from the client: a transport error per send.
        let dropped = FakeTransport()
        await dropped.fail(.any, times: 10_000, then: .status(500))
        let report = try await ServerStateTest.mirror(setup, transport: dropped).refresh(trigger: .settingsOpened)

        // Sieve sends nothing for an account with it off, so it is the one kind that
        // "refreshes" — from the stored account row, to the same disabled row.
        #expect(report.refreshed == [.sieve])
        #expect(Set(report.failed.keys) == Set(ServerStateKind.allCases).subtracting([.sieve]))
        #expect(try await ServerStateTest.snapshot(setup) == before)
    }

    @Test("offline: a refresh sends nothing and touches nothing")
    func offlineRefreshIsANoOp() async throws {
        let setup = try await ServerStateTest.store()
        let good = FakeTransport()
        try await ServerStateTest.stubEverything(good)
        let mirror = try ServerStateTest.mirror(setup, transport: good)
        await mirror.refresh(trigger: .launch)
        let before = try await ServerStateTest.snapshot(setup)
        let sent = await good.sendCount

        await mirror.apply(conditions: MirrorConditions(isOffline: true))
        let report = await mirror.refresh(trigger: .settingsOpened)
        await mirror.refreshOutbox()

        #expect(report.skippedOffline)
        #expect(await good.sendCount == sent)
        #expect(try await ServerStateTest.snapshot(setup) == before)
    }

    // MARK: - Account mapping

    @Test("the accounts refresh writes the signature and settings the payload carries, never a blank")
    func accountSettingsFromPayload() throws {
        let accounts = try JSONDecoder().decode(
            [RawBacked<Account>].self,
            from: try FixtureBytes.data("accounts-signatures.json")
        )
        let account = try #require(accounts.first)
        let write = try MirrorMapping.accountWrite(account, identity: MirrorTest.identity)
        let raw = try #require((try ServerStateTest.json("accounts-signatures.json") as? [[String: Any]])?.first)

        #expect(write.signature == raw["signature"] as? String)
        #expect(write.signature != nil)
        #expect(write.editorMode == raw["editorMode"] as? String)
        #expect(write.signatureMode == (raw["signatureMode"] as? NSNumber)?.intValue)
        #expect(write.classificationEnabled == (raw["classificationEnabled"] as? Bool))
        #expect(write.outOfOfficeFollowsSystem == (raw["outOfOfficeFollowsSystem"] as? Bool))
        #expect(write.isDelegated == (raw["isDelegated"] as? Bool))
    }

    // MARK: - Outbox poll

    @Test("the outbox is re-read every 60 s while non-empty and the poll stops once it is empty")
    func outboxPollsWhileNonEmpty() async throws {
        let drained = try #require(
            ((try ServerStateTest.json("outbox-drained.json") as? [String: Any])?["data"] as? [String: Any])?[
                "messages"]
                as? [Any]
        )
        try #require(drained.isEmpty, "outbox-drained.json must be the empty outbox")
        let setup = try await ServerStateTest.store()
        let transport = FakeTransport()
        await transport.stubSequence(
            ServerStateTest.route("outbox"),
            [try .fixture("outbox.json"), try .fixture("outbox.json"), try .fixture("outbox-drained.json")]
        )
        let sleeper = RecordingSleeper()
        let mirror = try ServerStateTest.mirror(
            setup,
            transport: transport,
            configuration: ServerStateTest.configuration(sleep: { try await sleeper.sleep($0) })
        )

        await mirror.refreshOutbox()
        #expect(try await setup.store.outboxMessages().isEmpty == false)
        await (await mirror.outboxPoll)?.value

        #expect(await transport.requestPaths.filter { $0.hasSuffix("/outbox") }.count == 3)
        #expect(sleeper.durations == [.seconds(60), .seconds(60)])
        #expect(try await setup.store.outboxMessages().isEmpty)
        #expect(await mirror.outboxPoll == nil)
    }

    @Test("a failed outbox read keeps the queued rows and keeps polling")
    func outboxPollSurvivesAFailure() async throws {
        let setup = try await ServerStateTest.store()
        let transport = FakeTransport()
        await transport.stubSequence(
            ServerStateTest.route("outbox"),
            [try .fixture("outbox.json"), .status(500), try .fixture("outbox-drained.json")]
        )
        let sleeper = RecordingSleeper()
        let mirror = try ServerStateTest.mirror(
            setup,
            transport: transport,
            configuration: ServerStateTest.configuration(sleep: { try await sleeper.sleep($0) })
        )
        await mirror.refreshOutbox()
        let queued = try await setup.store.outboxMessages()

        await (await mirror.outboxPoll)?.value

        #expect(!queued.isEmpty)
        #expect(sleeper.durations.count == 2, "one sleep before the failure, one before the empty read")
        #expect(try await setup.store.outboxMessages().isEmpty)
    }

    // MARK: - Follow-up

    @Test("follow-up check writes one row per message and reports nothing answered")
    func followUpCheck() async throws {
        let seeded = try await SyncTest.seed(messages: Array(try Recorded.inbox().prefix(2)))
        let loginId = try #require(try await seeded.store.ensureLogin(MirrorTest.identity).id)
        let transport = FakeTransport()
        await transport.stub(
            ServerStateTest.route("follow-up/check-message-ids"), with: try .fixture("follow-up-check.json"))
        let answered = Mutex<[Int64]>([])
        let mirror = ServerStateMirror(
            store: seeded.store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity,
            configuration: ServerStateTest.configuration(),
            onFollowedUp: { ids in answered.withLock { $0 += ids } }
        )
        let ids = Array(seeded.localByRemote.values)

        await mirror.checkFollowUps(messageIds: ids)

        for id in ids {
            let row = try #require(
                try await seeded.store.serverResult(kind: "followUp", key: String(id), loginId: loginId)
            )
            #expect(
                try ServerResultPayload(payloadJSON: row.payloadJSON)
                    == .ready(.object(["wasFollowedUp": .bool(false)])))
        }
        #expect(answered.withLock { $0 }.isEmpty)
        let body = try #require(await transport.requests.last?.httpBody)
        let sent = try JSONDecoder().decode([String: [Int]].self, from: body)
        #expect(Set(sent["messageIds"] ?? []) == Set(seeded.localByRemote.keys.map(Int.init)))
    }

    @Test("a failed follow-up check writes nothing")
    func followUpCheckFailure() async throws {
        let seeded = try await SyncTest.seed(messages: Array(try Recorded.inbox().prefix(1)))
        let loginId = try #require(try await seeded.store.ensureLogin(MirrorTest.identity).id)
        let transport = FakeTransport()
        await transport.stub(ServerStateTest.route("follow-up/check-message-ids"), with: .status(500))
        let mirror = ServerStateMirror(
            store: seeded.store,
            client: try MirrorTest.client(transport),
            identity: MirrorTest.identity,
            configuration: ServerStateTest.configuration()
        )
        let id = try #require(seeded.localByRemote.values.first)

        await mirror.checkFollowUps(messageIds: [id])

        #expect(try await seeded.store.serverResult(kind: "followUp", key: String(id), loginId: loginId) == nil)
    }

    // MARK: - Cadence

    @Test("a deep reconcile refreshes server state, after the drain")
    func deepReconcileRefreshesServerState() async throws {
        let seeded = try await SyncTest.seed(messages: try Recorded.inbox())
        let transport = FakeTransport()
        try await SyncTest.stubBoilerplate(transport)
        try await ServerStateTest.stubEverything(transport)
        await transport.stub(
            MirrorTest.messagesRoute(mailboxId: seeded.inboxRemoteId), with: try Recorded.page(try Recorded.inbox()))
        let client = try MirrorTest.client(transport)
        let serverState = ServerStateMirror(
            store: seeded.store,
            client: client,
            identity: MirrorTest.identity,
            configuration: ServerStateTest.configuration()
        )
        let scheduler = SyncScheduler(
            store: seeded.store,
            client: client,
            accountId: seeded.accountId,
            serverState: serverState,
            configuration: SyncTest.configuration(clock: TestClock())
        )

        await scheduler.deepReconcile(mailboxId: seeded.inboxId)

        #expect(await serverState.lastReport?.trigger == .deepReconcile)
        #expect(await transport.requestPaths.contains { $0.hasSuffix("/quick-actions") })
    }

    @Test("a trigger arriving during a refresh joins it instead of starting another")
    func concurrentTriggersCoalesce() async throws {
        let setup = try await ServerStateTest.store()
        let transport = FakeTransport()
        try await ServerStateTest.stubEverything(transport)
        let gate = GatedTransport(inner: transport, holding: MirrorTest.accountsRoute)
        let mirror = ServerStateMirror(
            store: setup.store,
            client: try ServerStateTest.client(gate),
            identity: MirrorTest.identity,
            configuration: ServerStateTest.configuration()
        )

        async let launch = mirror.refresh(trigger: .launch)
        await gate.waitForHeld()
        async let settings = mirror.refresh(trigger: .settingsOpened)
        // No timer: the gate holds the launch refresh until the second trigger has joined.
        while await mirror.joinedRefreshes == 0 { await Task.yield() }
        await gate.open()
        let (first, second) = await (launch, settings)

        #expect(first == second)
        #expect(await transport.requestPaths.filter { $0.hasSuffix("/accounts") }.count == 1)
    }
}
