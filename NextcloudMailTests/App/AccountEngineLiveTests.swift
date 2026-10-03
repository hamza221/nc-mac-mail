// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import Testing

@testable import NextcloudMail

/// The app shell's wiring, against a live server, with no sign-in screen in the way.
///
/// Off by default and never part of `make test-app`: it opens sockets and writes a file, both
/// of which `docs/delivery/definition-of-done.md` bans from the normal suite. It follows the
/// pattern `MirrorLiveMeasurementTests` set in `NCMailSync`, and it exists because the one
/// thing no unit test can answer is whether an account row, a coordinator, a drainer and a
/// scheduler actually appear when the engine is pointed at a real Nextcloud.
///
/// ```
/// NCMAIL_LIVE_SHELL=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/AccountEngineLiveTests test
/// ```
@Suite("App shell against a live server")
@MainActor
struct AccountEngineLiveTests {
    nonisolated static let serverEnvironment = ProcessInfo.processInfo.environment["NCMAIL_LIVE_SHELL"]

    enum LiveError: Error { case missingEnvironment, timedOut }

    @Test(.enabled(if: AccountEngineLiveTests.serverEnvironment != nil))
    func theEngineMirrorsWhatTheColumnsRead() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["NCMAIL_LIVE_SHELL"],
            let server = URL(string: raw),
            let user = environment["NCMAIL_LIVE_USER"],
            let password = environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ncmail-shell-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory))
        let status = AppStatus()
        let engine = AccountEngine(store: store, status: status)
        defer { engine.stopAll() }

        let session = AccountSession(
            server: server,
            loginName: user,
            client: MailClient(server: server, credentials: BasicCredentials(loginName: user, appPassword: password))
        )

        // The server answers this login at all. Asserted first so that a failure here reads
        // as "the credentials or the host are wrong" rather than as a silent timeout below.
        let remoteAccounts = try await session.client.get(.accounts)
        #expect(remoteAccounts.isEmpty == false)

        // Exactly what `AppSession.start()` does with the accounts it read from the Keychain.
        engine.start(accounts: [session])

        // The sidebar's first row: one account, written by discovery and delivered by the
        // observation the engine starts a coordinator from.
        let accounts = try await eventually { try await store.accounts() }
        let account = try #require(accounts.first)
        #expect(account.serverURL == server.absoluteString)

        // The coordinator for that row is running, which is what makes a message view able to
        // ask for a body.
        let running = try await eventually { engine.account(id: account.id) }
        #expect(running.session.id == session.id)

        // The middle column's rows come from mailboxes, and the footer's number from the
        // coordinator's progress stream.
        let mailboxes = try await eventually { try await store.mailboxes(accountId: account.id) }
        let progress = try await eventually { status.mirror }

        Issue.record(
            """
            live shell: \(accounts.count) account row(s), \(mailboxes.count) mailboxes, \
            footer says \(progress.bodiesPresent + progress.bodiesFailed) of \
            \(progress.totalMessages), \(status.pendingFailures) failing operations
            """
        )
        #expect(mailboxes.isEmpty == false)
    }

    /// Polls until a value arrives. The engine is deliberately fire-and-forget — every part of
    /// it answers through the database — so there is nothing to await on directly.
    private func eventually<Value>(
        within seconds: Double = 30,
        _ read: () async throws -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let value = try await read(), !isEmptyCollection(value) { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LiveError.timedOut
    }

    private func isEmptyCollection(_ value: Any) -> Bool {
        (value as? any Collection)?.isEmpty ?? false
    }
}
