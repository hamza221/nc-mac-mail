// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import Testing

@testable import NextcloudMail

/// Every Settings › Storage action, against a live server, once.
///
/// Off by default and never part of `make test-app`, matching
/// `MirrorLiveMeasurementTests` in `NCMailSync` and gated the same way this workstream's
/// brief asks for: the Keychain half only runs when `NCMAIL_KEYCHAIN_TESTS=1` is also set,
/// because it prompts the developer otherwise.
///
/// ```
/// NCMAIL_LIVE_MIRROR=http://nextcloud.local NCMAIL_LIVE_USER=admin NCMAIL_LIVE_PASSWORD=admin \
///   NCMAIL_KEYCHAIN_TESTS=1 \
///   xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail -destination 'platform=macOS' \
///   -only-testing:NextcloudMailTests/SettingsStoreLiveTests test
/// ```
@Suite("SettingsStore against a live server")
struct SettingsStoreLiveTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static var hasLiveServer: Bool { environment["NCMAIL_LIVE_MIRROR"] != nil }
    nonisolated private static var hasKeychain: Bool { environment["NCMAIL_KEYCHAIN_TESTS"] == "1" }

    enum LiveError: Error { case missingEnvironment }

    @Test(.enabled(if: SettingsStoreLiveTests.hasLiveServer && SettingsStoreLiveTests.hasKeychain))
    func everyStorageAndSignOutAction() async throws {
        guard
            let raw = Self.environment["NCMAIL_LIVE_MIRROR"],
            let server = URL(string: raw),
            let user = Self.environment["NCMAIL_LIVE_USER"],
            let password = Self.environment["NCMAIL_LIVE_PASSWORD"]
        else { throw LiveError.missingEnvironment }

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ncmail-settings-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try MailStore(url: folder.appending(path: "mirror.sqlite", directoryHint: .notDirectory))
        let mailClient = MailClient(
            server: server,
            credentials: BasicCredentials(loginName: user, appPassword: password),
            clientVersion: "settings-live-test"
        )

        // A real Keychain item, the same one `AppSession.signedIn(_:)` would have written,
        // so `SettingsStore.signOut` has something real to remove at the end.
        let realCredentials = Credentials(server: server, loginName: user, appPassword: password)
        try Keychain.save(realCredentials)
        defer { try? Keychain.delete(server: server, loginName: user) }

        let accounts = try await MirrorCoordinator.discoverAccounts(
            store: store,
            client: mailClient,
            identity: ServerIdentity(serverURL: server, loginName: user)
        )
        let account = try #require(accounts.first)

        let session = AccountSession(server: server, loginName: user, client: mailClient)
        let settingsStore = SettingsStore(store: store, sessions: [session])

        // A full backfill, the same one `MirrorCoordinator` runs at sign-in, so there is a
        // real body to remove and re-download below. `awaitCurrentRun()` is `NCMailSync`'s
        // own way to wait for a run and is not `public`, so this test polls the same
        // database column the app itself would watch instead.
        let coordinator = MirrorCoordinator(store: store, client: mailClient, accountId: account.id)
        await coordinator.start()
        let mirrored = try await waitForMirrorComplete(store: store, accountId: account.id)
        #expect(mirrored.bodiesPresent > 0)

        // Sign-out's queue question, on an account with nothing queued.
        let accountRow = try #require(try await store.account(id: account.id))
        #expect(await settingsStore.pendingQueueCount(for: accountRow) == 0)

        // Pause, for real: the coordinator this workstream built stops, and the flag
        // persists.
        await settingsStore.pauseBackfill(accountId: account.id)
        #expect(settingsStore.pausedAccountIDs.contains(account.id))
        let pausedState = try #require(try await store.account(id: account.id)).mirrorState
        #expect(pausedState == .paused)

        // Resume, for real: the same coordinator this workstream cached starts again.
        await settingsStore.resumeBackfill(accountId: account.id)
        #expect(!settingsStore.pausedAccountIDs.contains(account.id))

        // Check for missing messages: WS-05's deep reconcile, actually run.
        await settingsStore.checkForMissingMessages(accountId: account.id)

        // Remove local copies: bodies and attachments gone, envelopes kept.
        let beforeRemoval = try await store.storageFootprint(accountId: account.id)
        #expect(beforeRemoval.bodyBytes > 0)
        await settingsStore.removeLocalCopies(accountId: account.id)
        let afterRemoval = try await store.storageFootprint(accountId: account.id)
        #expect(afterRemoval.bodyBytes == 0)
        #expect(afterRemoval.messageCount == beforeRemoval.messageCount)

        // Re-download: the reset plus a real re-fetch of at least one body.
        // `reDownload` only awaits starting the coordinator, not finishing it, so this polls
        // for the first body the same way the storage panel's own periodic refresh would see
        // it land, rather than for the whole backfill to finish again.
        await settingsStore.reDownload(accountId: account.id)
        let redownloaded = try await waitForAnyBodyPresent(store: store, accountId: account.id)
        #expect(redownloaded.bodiesPresent > 0)

        // Sign out, removing local copies: the Keychain item and the account row are both
        // gone, and neither operation touched the server.
        await settingsStore.signOut(account: accountRow, removeLocalCopies: true)
        #expect(try Keychain.load(server: server, loginName: user) == nil)
        #expect(try await store.account(id: account.id) == nil)
    }

    /// Polls `mirrorProgress` until the backfill is complete, rather than sleeping for a
    /// guessed duration or reaching for `NCMailSync`'s own, non-public `awaitCurrentRun()`.
    /// A live-server test is not the fast suite `definition-of-done.md` bars sleeping in; it
    /// is the one place this codebase already accepts wall-clock time as the cost of asking
    /// a real server a question.
    private func waitForMirrorComplete(
        store: MailStore,
        accountId: Int64,
        timeout: Duration = .seconds(300)
    ) async throws -> MirrorProgress {
        let deadline = ContinuousClock.now + timeout
        while true {
            let progress = try await store.mirrorProgress(accountId: accountId)
            if progress.isComplete { return progress }
            guard ContinuousClock.now < deadline else { return progress }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func waitForAnyBodyPresent(
        store: MailStore,
        accountId: Int64,
        timeout: Duration = .seconds(120)
    ) async throws -> MirrorProgress {
        let deadline = ContinuousClock.now + timeout
        while true {
            let progress = try await store.mirrorProgress(accountId: accountId)
            if progress.bodiesPresent > 0 { return progress }
            guard ContinuousClock.now < deadline else { return progress }
            try await Task.sleep(for: .seconds(2))
        }
    }
}
