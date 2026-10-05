// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// The brief's acceptance: a folder created and then renamed while offline appears on the
/// server, under its new name, once the queue drains.
///
/// "Offline" is a `MutationQueue` with no drainer, which is exactly what the app has with no
/// route: the sidebar writes the queue and the mirror, nothing is sent. Reconnecting is one
/// `OperationDrainer.drain()`. The rename targets the create's negative placeholder id, so
/// this also proves the drain swaps it for the server's (ADR-0081). The folder is deleted the
/// same way at the end.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://localhost NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild test -project NextcloudMail.xcodeproj -scheme NextcloudMail \
///   -destination 'platform=macOS' -only-testing:NextcloudMailTests/SidebarLiveTests
/// ```
@MainActor
@Suite("Sidebar against a live server")
struct SidebarLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: SidebarLiveTests.hasLiveServer))
    func offlineCreateAndRenameAppearAfterDrain() async throws {
        guard
            let raw = Self.environment["NCMAIL_LIVE_MIRROR"], let server = URL(string: raw),
            let user = Self.environment["NCMAIL_LIVE_USER"],
            let password = Self.environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let store = try MailStore.inMemory()
        let client = MailClient(
            server: server, credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "sidebar-live-test")
        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store, client: client, identity: ServerIdentity(serverURL: server, loginName: user))
        let account = try #require(accounts.first)

        func serverNames() async throws -> [String] {
            try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId))).entries.map(\.value.name)
        }
        let list = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
        try await store.upsert(
            mailboxes: try list.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
            accountId: account.id)

        let model = SidebarStore(store: store)
        model.attach(
            SidebarServices(
                queue: { _ in MutationQueue(store: store) },
                run: { _, _ in .success },
                requestQuota: { _ in },
                move: { _, _ in }
            ))
        model.start()
        #expect(await settled { model.mailboxRows[account.id]?.isEmpty == false })

        let suffix = String(UUID().uuidString.prefix(8))
        let created = "WS28 Live \(suffix)"
        let renamed = "WS28 Renamed \(suffix)"

        // Offline: both land locally, nothing reaches the server.
        await model.createFolder(named: created, accountId: account.id)
        #expect(await settled { model.mailboxRows[account.id]?.contains { $0.name == created } == true })
        let placeholder = try #require(model.mailboxRows[account.id]?.first { $0.name == created })
        await model.renameFolder(placeholder, to: renamed, accountId: account.id)
        #expect(await settled { model.mailboxRows[account.id]?.contains { $0.name == renamed } == true })
        #expect(
            try await store.pendingOperations(accountId: account.id).map(\.kind) == ["createMailbox", "renameMailbox"])
        #expect(try await !serverNames().contains(created))
        #expect(try await !serverNames().contains(renamed))

        // Reconnect.
        let drainer = OperationDrainer(store: store, client: client, accountId: account.id)
        let started = ContinuousClock.now
        await drainer.drain()
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(try await store.pendingOperations(accountId: account.id).isEmpty)
        let afterDrain = try await serverNames()
        #expect(afterDrain.contains(renamed))
        #expect(!afterDrain.contains(created))
        // The create's write-back must not overwrite the name the queued rename already set.
        let localAfterDrain = try await store.mailboxes(accountId: account.id).map(\.name)
        #expect(localAfterDrain.contains(renamed))

        // The next sync's mailbox refresh, as the engine would run it, then clean up
        // through the same path.
        let refreshed = try await client.get(Endpoint.mailboxes(accountId: Int(account.remoteId)))
        try await store.upsert(
            mailboxes: try refreshed.entries.map { try MirrorMapping.mailboxWrite($0, accountId: account.id) },
            accountId: account.id)
        #expect(await settled { model.mailboxRows[account.id]?.contains { $0.name == renamed } == true })
        let matching = try await store.mailboxes(accountId: account.id).filter { $0.name == renamed }
        #expect(matching.count == 1, "rows named \(renamed): \(matching.map(\.remoteId))")
        let row = try #require(model.mailboxRows[account.id]?.first { $0.name == renamed })
        await model.deleteFolder(row, accountId: account.id)
        await drainer.drain()
        #expect(try await !serverNames().contains(renamed))
        model.stop()
    }

    private func settled(_ condition: () -> Bool, attempts: Int = 4000) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
}
