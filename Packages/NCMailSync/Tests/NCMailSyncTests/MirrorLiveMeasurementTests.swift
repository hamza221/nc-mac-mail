// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NCMailSync

/// A whole mirror, against a live server, on disk, timed.
///
/// Off by default and never part of `make test`: it opens sockets and writes files, both of
/// which `docs/delivery/definition-of-done.md` bans from the normal suite. It exists
/// because "measure before optimising, and write the number down" needs something anyone
/// can re-run rather than a number in a pull request nobody can check.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   swift test --filter mirrorsAWholeAccount
/// ```
@Suite("Mirror against a live server")
struct MirrorLiveMeasurementTests {
    private static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_MIRROR"]

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: MirrorLiveMeasurementTests.serverEnvironment != nil))
    func mirrorsAWholeAccount() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_MIRROR"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        // `NCMAIL_LIVE_KEEP` leaves the file behind so `sqlite3 … dbstat` can say which
        // table the bytes went to. That question is how the sizing table in
        // `docs/architecture/local-mirror.md` got its per-message numbers.
        let keep = environment["NCMAIL_LIVE_KEEP"] == "1"
        let folder =
            keep
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ncmail-live", directoryHint: .isDirectory)
            : URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "ncmail-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: folder) } }

        let store = try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory))
        let counter = RequestCounter()
        let client = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            transport: CountingTransport(counter: counter),
            clientVersion: "measurement"
        )
        // The row before the coordinator: a local account id only exists once `GET /accounts`
        // has been mirrored under this login (ADR-0033).
        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: client,
            identity: ServerIdentity(serverURL: server, loginName: user)
        )
        let account = try #require(accounts.first)
        let coordinator = MirrorCoordinator(store: store, client: client, accountId: account.id)

        let started = ContinuousClock.now
        await coordinator.start()
        await coordinator.awaitCurrentRun()
        let elapsed = ContinuousClock.now - started

        try await store.vacuum()
        let progress = try await store.mirrorProgress(accountId: account.id)
        let footprint = try await store.storageFootprint(accountId: account.id)
        let bytesOnDisk = store.fileSizeOnDisk()

        // Reported as an issue because Swift Testing has no other way to put a measurement
        // where a human reads it, and a measurement nobody reads is not one.
        Issue.record(
            """
            live mirror: \(elapsed) wall clock, \(await counter.count) requests, \
            \(progress.totalMessages) envelopes, \(progress.bodiesPresent) bodies, \
            \(progress.bodiesFailed) failed, \(bytesOnDisk) bytes on disk after VACUUM, \
            \(footprint.bodyBytes) bytes of body text, at \(folder.path())
            """
        )
        #expect(progress.mailboxesRemaining == 0)
    }
}

/// Counts what the mirror actually asked the server for, which is the figure the honest
/// conversation with Nextcloud needs.
actor RequestCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

struct CountingTransport: MailTransport {
    let counter: RequestCounter
    private let inner = URLSessionTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await counter.increment()
        return try await inner.send(request)
    }
}
