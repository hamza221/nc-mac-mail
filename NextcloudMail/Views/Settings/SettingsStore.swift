// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// The Storage and Accounts tabs' live state, and the one place this workstream talks to
/// the sync engine.
///
/// Every read comes from `MailStore`, the same as everywhere else in the app
/// ([overview.md](../../../docs/architecture/overview.md#the-invariant)). Every action that
/// needs a live request builds a short-lived ``MirrorCoordinator``, ``SyncScheduler`` or
/// ``OperationDrainer`` of its own against the account's real `MailClient`, rather than
/// reaching into `AppSession.engine`. That covers Pause, Re-download, Check for missing
/// messages, and the queue question at sign-out. See this workstream's report for why, and
/// what `AccountEngine` would need to expose to remove the duplication.
@MainActor
@Observable
final class SettingsStore {
    private(set) var accounts: [AccountRecord] = []
    private(set) var footprints: [Int64: StorageFootprint] = [:]
    private(set) var progresses: [Int64: MirrorProgress] = [:]
    private(set) var pausedAccountIDs: Set<Int64> = []
    /// An account whose server-side sort order is `oldest`, read from `meta` if anything has
    /// ever written it there. Nothing does yet, so this is correct and simply empty until
    /// `NCMailSync` persists the reading it already makes once per coordinator. See
    /// ADR-0053 and this workstream's report.
    private(set) var slowMirrorAccountIDs: Set<Int64> = []
    /// An action is in flight for this account: the button row shows a spinner instead of
    /// its buttons.
    private(set) var busyAccountIDs: Set<Int64> = []
    /// The whole mirror file, shared by every account. `local-mirror.md` is explicit that
    /// it is one database for all accounts, so this cannot be attributed to one of them, and
    /// it is shown once rather than per row.
    private(set) var mirrorFileSizeOnDisk: Int64 = 0

    private let store: MailStore
    private var sessionsByIdentity: [String: AccountSession]
    private var accountsObservation: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?
    /// Reused across Pause/Resume presses in one Settings session so the second press acts
    /// on the same run the first one started. It does not survive the Settings window
    /// closing and reopening. See the report for the residual gap that leaves.
    private var coordinators: [Int64: MirrorCoordinator] = [:]

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "settings")

    init(store: MailStore, sessions: [AccountSession]) {
        self.store = store
        sessionsByIdentity = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// `AppSession.accounts` can grow after Settings has already started, when the 401 modal
    /// re-authenticates one. The view calls this whenever the session's account list changes.
    func updateSessions(_ sessions: [AccountSession]) {
        sessionsByIdentity = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// The client this workstream would use for one account row, when a Keychain entry for
    /// it was loaded this launch. Nil is the ordinary answer for a row `AccountEngine` itself
    /// has not started either. See its `apply(rows:)` and the log line it writes.
    func client(for account: AccountRecord) -> MailClient? {
        sessionsByIdentity[AccountSession.identifier(server: account.serverURL, loginName: account.loginName)]?.client
    }

    // MARK: - Lifecycle

    func start() {
        guard accountsObservation == nil else { return }
        accountsObservation = Task { [weak self] in
            guard let store = self?.store else { return }
            do {
                for try await rows in store.observeAccounts() {
                    guard let self else { return }
                    accounts = rows
                    await refreshAll()
                }
            } catch {
                Self.logger.error("account observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshAll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        accountsObservation?.cancel()
        accountsObservation = nil
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    // MARK: - Storage panel reads

    /// `MirrorProgress` and `StorageFootprint` are one-shot reads, not `StoreObservation`s
    /// ([MailStore+Accounts.swift](../../../Packages/NCMailStore/Sources/NCMailStore/Queries/MailStore+Accounts.swift)),
    /// so the panel polls rather than watches. Three seconds is often enough to feel live
    /// without turning a quiet backfill into a busy timer; see the report for the case this
    /// leaves out.
    private func refreshAll() async {
        var newFootprints: [Int64: StorageFootprint] = [:]
        var newProgresses: [Int64: MirrorProgress] = [:]
        var newPaused: Set<Int64> = []
        var newSlow: Set<Int64> = []
        for account in accounts {
            if let footprint = try? await store.storageFootprint(accountId: account.id) {
                newFootprints[account.id] = footprint
            }
            if let progress = try? await store.mirrorProgress(accountId: account.id) {
                newProgresses[account.id] = progress
            }
            if await isPaused(accountId: account.id) {
                newPaused.insert(account.id)
            }
            if await hasSlowSortOrder(accountId: account.id) {
                newSlow.insert(account.id)
            }
        }
        footprints = newFootprints
        progresses = newProgresses
        pausedAccountIDs = newPaused
        slowMirrorAccountIDs = newSlow
        mirrorFileSizeOnDisk = store.fileSizeOnDisk()
    }

    private func refreshOne(_ accountId: Int64) async {
        if let footprint = try? await store.storageFootprint(accountId: accountId) {
            footprints[accountId] = footprint
        }
        if let progress = try? await store.mirrorProgress(accountId: accountId) {
            progresses[accountId] = progress
        }
        if await isPaused(accountId: accountId) {
            pausedAccountIDs.insert(accountId)
        } else {
            pausedAccountIDs.remove(accountId)
        }
        mirrorFileSizeOnDisk = store.fileSizeOnDisk()
    }

    /// The same key `MirrorCoordinator.pauseKey(_:)` writes and reads, duplicated here
    /// because that constant is not `public`. Load-bearing: a mismatch would mean Settings'
    /// Pause and a real backfill's own restart silently disagree. Flagged in the report.
    private static func pauseMetaKey(_ accountId: Int64) -> String { "mirror.paused.\(accountId)" }

    private func isPaused(accountId: Int64) async -> Bool {
        ((try? await store.metaValue(forKey: Self.pauseMetaKey(accountId))) ?? nil) == "1"
    }

    /// See ``slowMirrorAccountIDs``: reads a key nothing writes yet.
    private static func sortOrderMetaKey(_ accountId: Int64) -> String { "mirror.sortOrder.\(accountId)" }

    private func hasSlowSortOrder(accountId: Int64) async -> Bool {
        (try? await store.metaValue(forKey: Self.sortOrderMetaKey(accountId))) == "oldest"
    }

    // MARK: - General settings

    private static let markAsReadMetaKey = "settings.markAsReadDelay"

    func markAsReadDelay() async -> MarkAsReadDelay {
        let raw = (try? await store.metaValue(forKey: Self.markAsReadMetaKey)) ?? nil
        return MarkAsReadDelay(metaValue: raw)
    }

    func setMarkAsReadDelay(_ delay: MarkAsReadDelay) async {
        try? await store.setMetaValue(delay.metaValue, forKey: Self.markAsReadMetaKey)
    }

    // MARK: - Storage actions

    /// Bodies, inline image data and the search rows for this account, gone; envelopes kept.
    /// `local-mirror.md`'s `removeLocalCopies` exactly, plus the `VACUUM` the store
    /// deliberately leaves to the caller because it is slow.
    func removeLocalCopies(accountId: Int64) async {
        busyAccountIDs.insert(accountId)
        defer { busyAccountIDs.remove(accountId) }
        do {
            try await store.removeLocalCopies(accountId: accountId, resetBodyState: false)
            try await store.vacuum()
        } catch {
            Self.logger.error(
                "remove local copies failed for account \(accountId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        await refreshOne(accountId)
    }

    /// The same clear, plus `bodyState = 'missing'`, which restarts stage 2. When a live
    /// client is available, this also starts a coordinator to actually run it, rather than
    /// leaving the reset sitting there until the next launch happens to start one.
    func reDownload(accountId: Int64) async {
        busyAccountIDs.insert(accountId)
        defer { busyAccountIDs.remove(accountId) }
        do {
            try await store.removeLocalCopies(accountId: accountId, resetBodyState: true)
            try await store.vacuum()
        } catch {
            Self.logger.error(
                "re-download reset failed for account \(accountId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            await refreshOne(accountId)
            return
        }
        if let client = accounts.first(where: { $0.id == accountId }).flatMap(client(for:)) {
            await coordinator(for: accountId, client: client).resume()
        }
        await refreshOne(accountId)
    }

    /// Persists the flag unconditionally, then asks the live coordinator to stop if this
    /// launch has one. A relaunch honours the flag either way, because `MirrorCoordinator`
    /// reads it at the top of `start()`.
    func pauseBackfill(accountId: Int64) async {
        busyAccountIDs.insert(accountId)
        defer { busyAccountIDs.remove(accountId) }
        if let client = accounts.first(where: { $0.id == accountId }).flatMap(client(for:)) {
            await coordinator(for: accountId, client: client).pause()
        } else {
            try? await store.setMetaValue("1", forKey: Self.pauseMetaKey(accountId))
        }
        await refreshOne(accountId)
    }

    func resumeBackfill(accountId: Int64) async {
        guard let client = accounts.first(where: { $0.id == accountId }).flatMap(client(for:)) else { return }
        busyAccountIDs.insert(accountId)
        defer { busyAccountIDs.remove(accountId) }
        await coordinator(for: accountId, client: client).resume()
        await refreshOne(accountId)
    }

    /// WS-05's deep reconcile, on demand. `SyncScheduler.deepReconcile(mailboxId:)`'s own
    /// doc comment names this exact button. `exclusively { }` inside it means this `await`
    /// returns only once the whole pass has finished, which is what lets the button show a
    /// "Checking" state rather than fire-and-forget.
    func checkForMissingMessages(accountId: Int64) async {
        guard let client = accounts.first(where: { $0.id == accountId }).flatMap(client(for:)) else { return }
        busyAccountIDs.insert(accountId)
        defer { busyAccountIDs.remove(accountId) }
        let scheduler = SyncScheduler(store: store, client: client, accountId: accountId)
        await scheduler.deepReconcile()
        await refreshOne(accountId)
    }

    private func coordinator(for accountId: Int64, client: MailClient) -> MirrorCoordinator {
        if let existing = coordinators[accountId] { return existing }
        let coordinator = MirrorCoordinator(store: store, client: client, accountId: accountId)
        coordinators[accountId] = coordinator
        return coordinator
    }

    // MARK: - Sign-out

    /// What to do about a non-empty queue before signing out
    /// ([offline-queue.md](../../../docs/architecture/offline-queue.md#sign-out-and-pending-work)).
    enum QueueDecision {
        case sendNow
        case discard
    }

    /// `drainer.summary().queued`, this workstream's brief in exactly those words. A fresh
    /// `OperationDrainer` answers truthfully regardless of whether it is the same instance
    /// that queued the rows: the summary is a database read, collapsed the same way any
    /// drainer would collapse it.
    func pendingQueueCount(for account: AccountRecord) async -> Int {
        guard let client = client(for: account) else {
            // No live client this launch to build a drainer with. The queue table itself
            // still answers, uncollapsed; a raw count is the honest fallback rather than
            // silently saying zero.
            return (try? await store.pendingOperations(accountId: account.id))?.count ?? 0
        }
        let drainer = OperationDrainer(store: store, client: client, accountId: account.id)
        return await drainer.summary().queued
    }

    /// **Send now** or **Discard**, then the answer honoured before sign-out proceeds.
    func resolveQueue(for account: AccountRecord, decision: QueueDecision) async {
        guard let client = client(for: account) else { return }
        let drainer = OperationDrainer(store: store, client: client, accountId: account.id)
        switch decision {
        case .sendNow: await drainer.drain()
        case .discard: await drainer.discardAll()
        }
    }

    /// Removes the Keychain item unconditionally, then either keeps the mirrored rows or
    /// deletes and `VACUUM`s them, per the user's choice.
    ///
    /// Deleting the row is also what stops this account's live `MirrorCoordinator`,
    /// `SyncScheduler` and `OperationDrainer`: `AccountEngine.apply(rows:)` already reacts to
    /// `store.observeAccounts()` losing a row by stopping everything it was running for it,
    /// so nothing here has to reach into `AppSession` to say so. Choosing **Keep** stops
    /// nothing this launch, because the account's `AccountSession.client` already has its
    /// app password captured in memory. It takes effect at the next launch instead, when the
    /// Keychain enumeration no longer finds it. See the report.
    func signOut(account: AccountRecord, removeLocalCopies: Bool) async {
        if let serverURL = URL(string: account.serverURL) {
            do {
                try Keychain.delete(server: serverURL, loginName: account.loginName)
            } catch {
                Self.logger.error(
                    "Keychain delete failed during sign-out: \(String(describing: error), privacy: .public)"
                )
            }
        }
        coordinators[account.id] = nil
        guard removeLocalCopies else { return }
        do {
            try await store.deleteAccount(id: account.id)
            try await store.vacuum()
        } catch {
            Self.logger.error(
                "removing local copies at sign-out failed for account \(account.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
