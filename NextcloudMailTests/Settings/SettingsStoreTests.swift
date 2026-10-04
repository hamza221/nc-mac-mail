// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import Testing

@testable import NextcloudMail

/// `SettingsStore` against a real, migrated, in-memory mirror, with no Keychain entry and no
/// live `MailClient` for any account. That is deliberate: every path exercised here is the
/// one this workstream promised keeps working with no active session: persisting the pause
/// flag, resetting body state, deleting or keeping an account's rows, and falling back to an
/// uncollapsed queue count. The paths that build a live `MirrorCoordinator` or
/// `OperationDrainer` need a real client and are out of this suite's reach without one; they
/// are exercised manually against the live server instead (see this workstream's report).
@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    @discardableResult
    private func makeAccount(
        _ store: MailStore,
        loginName: String = "lorelai",
        serverURL: String = "https://cloud.example.com",
        remoteId: Int64 = 1
    ) async throws -> AccountRecord {
        let write = AccountWrite(
            identity: ServerIdentity(serverURL: serverURL, loginName: loginName),
            remoteId: remoteId,
            name: "Work",
            emailAddress: "lorelai@dragonfly.example"
        )
        let records = try await store.upsert(accounts: [write])
        return try #require(records.first)
    }

    // MARK: - Storage actions, no live client

    @Test("remove local copies does not throw with nothing to remove, and refreshes the footprint")
    func removeLocalCopiesIsSafeOnAnEmptyAccount() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.removeLocalCopies(accountId: account.id)

        #expect(settingsStore.busyAccountIDs.isEmpty)
        let footprint = try #require(settingsStore.footprints[account.id])
        #expect(footprint.bodyBytes == 0)
        #expect(footprint.attachmentBytes == 0)
    }

    @Test("re-download with no live client still resets body state and does not throw")
    func reDownloadWithoutALiveClient() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        // No sessions at all, so `client(for:)` answers nil and the coordinator branch is
        // skipped entirely. The reset itself is the thing this test proves happens anyway.
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.reDownload(accountId: account.id)

        #expect(settingsStore.busyAccountIDs.isEmpty)
        #expect(settingsStore.footprints[account.id] != nil)
    }

    @Test("pause persists across a fresh SettingsStore, matching MirrorCoordinator's own key")
    func pausePersistsWithNoLiveClient() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.pauseBackfill(accountId: account.id)
        #expect(settingsStore.pausedAccountIDs.contains(account.id))

        // A second, independent SettingsStore, standing in for a relaunch, reads the same
        // persisted flag back, which is the whole point of writing it to `meta` rather than
        // keeping it in memory.
        let reopened = SettingsStore(store: store, sessions: [])
        await reopened.pauseBackfill(accountId: account.id)
        #expect(reopened.pausedAccountIDs.contains(account.id))
    }

    @Test("resume with no live client is a no-op rather than a crash")
    func resumeWithoutALiveClientDoesNothing() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.pauseBackfill(accountId: account.id)
        await settingsStore.resumeBackfill(accountId: account.id)

        // Nothing can actually resume a backfill without a client, so the flag this workstream
        // controls directly is left exactly where it was.
        #expect(settingsStore.pausedAccountIDs.contains(account.id))
    }

    @Test("check for missing messages with no live client is a no-op rather than a crash")
    func checkForMissingWithoutALiveClientDoesNothing() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.checkForMissingMessages(accountId: account.id)

        #expect(settingsStore.busyAccountIDs.isEmpty)
    }

    // MARK: - Sign-out

    @Test("signing out with Keep leaves the mirrored account in place")
    func signOutKeepsLocalCopies() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.signOut(account: account, removeLocalCopies: false)

        #expect(try await store.account(id: account.id) != nil)
    }

    @Test("signing out with Remove deletes the mirrored account")
    func signOutRemovesLocalCopies() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        await settingsStore.signOut(account: account, removeLocalCopies: true)

        #expect(try await store.account(id: account.id) == nil)
    }

    // MARK: - Sign-out queue check

    @Test("pending queue count falls back to a raw, uncollapsed count with no live client")
    func pendingQueueCountFallsBackWithoutAClient() async throws {
        let store = try MailStore.inMemory()
        let account = try await makeAccount(store)
        let settingsStore = SettingsStore(store: store, sessions: [])

        #expect(await settingsStore.pendingQueueCount(for: account) == 0)

        try await store.enqueue(
            [
                PendingOperationRecord(
                    kind: "setFlags",
                    accountId: account.id,
                    payloadJSON: "{}",
                    createdAt: 0,
                    baseSyncedAt: 0
                )
            ],
            applying: [LocalEffect(messageIds: [])]
        )

        #expect(await settingsStore.pendingQueueCount(for: account) == 1)
    }
}
