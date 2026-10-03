// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// The steady state, measured against a live server rather than asserted from a fixture.
///
/// Off by default and never part of `make test`, for the same reason as
/// ``MirrorLiveMeasurementTests``: it opens sockets. It exists because the brief asks two
/// questions a fake transport cannot answer — what a cycle really costs, and whether a
/// change made elsewhere really shows up here — and because "fast enough" is not a finding.
///
/// ```
/// NCMAIL_LIVE_SYNC=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter measuresASteadyStateCycle
/// ```
@Suite("Sync against a live server")
struct SyncLiveMeasurementTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_SYNC"]

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: SyncLiveMeasurementTests.serverEnvironment != nil))
    func measuresASteadyStateCycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_SYNC"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let meter = TransferMeter()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            transport: MeasuringTransport(meter: meter),
            clientVersion: "measurement"
        )
        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: client,
            identity: ServerIdentity(serverURL: server, loginName: user)
        )
        let account = try #require(accounts.first)

        // Envelopes only. An expensive path pauses stage 2 and never stage 1 (etiquette rule
        // 4), which is exactly the mirror this measurement wants: every envelope present, no
        // three minutes spent downloading bodies the question does not involve.
        let coordinator = MirrorCoordinator(store: store, client: client, accountId: account.id)
        await coordinator.apply(conditions: MirrorConditions(isExpensive: true))
        await coordinator.start()
        await coordinator.awaitCurrentRun()
        let mirrored = try await store.mirrorProgress(accountId: account.id)
        #expect(mirrored.mailboxesRemaining == 0)

        let clock = TestClock()
        let scheduler = SyncScheduler(
            store: store,
            client: client,
            accountId: account.id,
            configuration: SyncConfiguration(now: { clock.now }, sleep: { _ in })
        )

        let beforeFirst = await meter.snapshot()
        await scheduler.pass(mailboxIds: nil, forced: false)
        let afterFirst = await meter.snapshot()

        clock.advance(by: 1_000)
        await scheduler.pass(mailboxIds: nil, forced: false)
        let afterSecond = await meter.snapshot()

        clock.advance(by: 1_000)
        await scheduler.pass(mailboxIds: nil, forced: false)
        let afterThird = await meter.snapshot()

        let reconcileStart = await meter.snapshot()
        await scheduler.deepReconcile()
        let afterReconcile = await meter.snapshot()

        let mailboxes = try await store.mailboxes(accountId: account.id).count { $0.isMirrored && $0.isSelectable }
        let steadyRequests = afterThird.requests - afterSecond.requests
        let steadyBytes = afterThird.bytes - afterSecond.bytes
        let metrics = await scheduler.metrics

        Issue.record(
            """
            live sync, \(mirrored.totalMessages) envelopes across \(mailboxes) mirrored mailboxes:
              first cycle      \(afterFirst.requests - beforeFirst.requests) requests, \
            \(afterFirst.bytes - beforeFirst.bytes) bytes
              second cycle     \(afterSecond.requests - afterFirst.requests) requests, \
            \(afterSecond.bytes - afterFirst.bytes) bytes
              steady cycle     \(steadyRequests) requests, \(steadyBytes) bytes
              per hour at 2 min  \(steadyRequests * 30) requests, \(steadyBytes * 30) bytes
              deep reconcile   \(afterReconcile.requests - reconcileStart.requests) requests, \
            \(afterReconcile.bytes - reconcileStart.bytes) bytes
              envelopes written \(metrics.envelopesWritten), deleted \(metrics.messagesDeleted), \
            envelope bytes \(metrics.envelopeBytesDown)
            """
        )

        // The claim ADR-0015 rests on: the cost of a cycle follows the window, not the
        // mirror. Two requests per mailbox with rows in it, one for a mailbox without.
        #expect(steadyRequests <= mailboxes * 2)
        #expect(metrics.lastError == nil)
    }

    /// A flag set the way the web client sets it, then one sync, then the local row.
    ///
    /// Reversible on purpose: it flips `flagged` on the newest inbox message and flips it
    /// back, so a shared test server is left as it was found.
    @Test(.enabled(if: SyncLiveMeasurementTests.serverEnvironment != nil))
    func seesAChangeMadeElsewhere() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_SYNC"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "measurement"
        )
        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: client,
            identity: ServerIdentity(serverURL: server, loginName: user)
        )
        let account = try #require(accounts.first)
        let coordinator = MirrorCoordinator(store: store, client: client, accountId: account.id)
        await coordinator.apply(conditions: MirrorConditions(isExpensive: true))
        await coordinator.start()
        await coordinator.awaitCurrentRun()

        let inbox = try #require(
            try await store.mailboxes(accountId: account.id).first { $0.specialRole?.lowercased() == "inbox" }
        )
        let newest = try #require(
            try await store.messages(mailboxId: inbox.id, view: .flat, range: 0..<1).first
        )
        let scheduler = SyncScheduler(store: store, client: client, accountId: account.id)

        for wanted in [true, false] {
            _ = try await client.put(
                .setFlags(messageId: Int(newest.remoteId)),
                body: SetFlagsRequest(flagged: wanted)
            )
            await scheduler.syncNow(mailboxId: inbox.id)
            let record = try #require(try await store.message(id: newest.id))
            #expect(record.isFlagged == wanted, "a flag set elsewhere is mirrored on the next cycle")
        }
    }
}

/// Requests and response bytes, which is what "steady-state traffic" means.
actor TransferMeter {
    struct Snapshot: Sendable {
        var requests: Int
        var bytes: Int
    }

    private var requests = 0
    private var bytes = 0

    func record(bytes newBytes: Int) {
        requests += 1
        bytes += newBytes
    }

    func snapshot() -> Snapshot {
        Snapshot(requests: requests, bytes: bytes)
    }
}

struct MeasuringTransport: MailTransport {
    let meter: TransferMeter
    private let inner = URLSessionTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        await meter.record(bytes: data.count)
        return (data, response)
    }
}
