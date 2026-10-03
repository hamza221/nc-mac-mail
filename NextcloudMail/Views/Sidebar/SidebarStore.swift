// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import OSLog
import Observation

/// The sidebar's accounts and mailbox trees, live.
///
/// Two layers of observation, one per account: `store.observeAccounts()` says which accounts
/// exist, and one `store.observeMailboxes(accountId:)` per account says what is in each one.
/// `MailboxTree.build(from:)` turns the second into what the view draws -- a pure function
/// over rows, run again every time the rows change, never touching I/O itself.
///
/// Nothing here reaches the network. Reads come from `MailStore`; sync is what moves them
/// there ([overview.md](../../../docs/architecture/overview.md#the-invariant)).
@MainActor
@Observable
final class SidebarStore {
    private(set) var accounts: [AccountRecord] = []
    private(set) var mailboxNodes: [Int64: [MailboxNode]] = [:]
    /// Node ids the user collapsed, per account. Absence means expanded, which is the
    /// sidebar's default shape ([ux-spec.md](../../../docs/product/ux-spec.md#sidebar)).
    private(set) var collapsedNodeIDs: [Int64: Set<String>] = [:]
    /// The mailbox whose Get info panel is open, if any. Settable so the sheet's binding can
    /// clear it when the panel closes.
    var infoTarget: MailboxInfoTarget?

    private let store: MailStore
    private var accountsObservation: Task<Void, Never>?
    private var accountTasks: [Int64: Task<Void, Never>] = [:]

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "sidebar")

    init(store: MailStore) {
        self.store = store
    }

    /// Starts observing. Safe to call more than once: a run already in progress is left alone.
    func start() {
        guard accountsObservation == nil else { return }
        accountsObservation = Task { [weak self] in
            guard let store = self?.store else { return }
            do {
                for try await fresh in store.observeAccounts() {
                    guard let self else { return }
                    apply(accounts: fresh)
                }
            } catch {
                Self.logger.error("account observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The view calls this when the column goes away. Cancelling every task is enough --
    /// dropping the iterator terminates the store's sequence, which terminates the database
    /// observation with it ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
    func stop() {
        accountsObservation?.cancel()
        accountsObservation = nil
        for task in accountTasks.values { task.cancel() }
        accountTasks.removeAll()
    }

    private func apply(accounts fresh: [AccountRecord]) {
        accounts = fresh
        let freshIDs = Set(fresh.map(\.id))
        for (accountId, task) in accountTasks where !freshIDs.contains(accountId) {
            task.cancel()
            accountTasks[accountId] = nil
            mailboxNodes[accountId] = nil
            collapsedNodeIDs[accountId] = nil
        }
        for account in fresh where accountTasks[account.id] == nil {
            accountTasks[account.id] = Task { [weak self] in
                await self?.loadCollapsedNodeIDs(accountId: account.id)
                await self?.observeMailboxes(accountId: account.id)
            }
        }
    }

    private func observeMailboxes(accountId: Int64) async {
        do {
            for try await records in store.observeMailboxes(accountId: accountId) {
                // Cancelling this account's task races the row's own cascade-deleted mailboxes
                // firing an empty page through this same loop: cancellation is cooperative, so
                // an iteration already resumed with a value can still run after `apply(accounts:)`
                // has removed this id. Re-checking against the current, authoritative `accounts`
                // right before the write -- rather than trusting why this task started -- is
                // what keeps a removed account's entry from reappearing as an empty array.
                guard accounts.contains(where: { $0.id == accountId }) else { return }
                mailboxNodes[accountId] = MailboxTree.build(from: records.map(\.treeRow))
            }
        } catch {
            Self.logger.error(
                "mailbox observation stopped for account \(accountId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Expansion

    func isExpanded(accountId: Int64, node: MailboxNode) -> Bool {
        !(collapsedNodeIDs[accountId]?.contains(node.id) ?? false)
    }

    func setExpanded(_ expanded: Bool, accountId: Int64, node: MailboxNode) {
        var collapsed = collapsedNodeIDs[accountId] ?? []
        if expanded {
            collapsed.remove(node.id)
        } else {
            collapsed.insert(node.id)
        }
        collapsedNodeIDs[accountId] = collapsed
        persistCollapsedNodeIDs(collapsed, accountId: accountId)
    }

    /// One `meta` row per account holding every collapsed node's id, rather than one row per
    /// mailbox: a 200-mailbox account would otherwise mean 200 point reads before the first
    /// frame, and expansion is the kind of state a single small JSON array already fits.
    private static func collapsedKey(accountId: Int64) -> String { "sidebar.collapsedNodeIDs.\(accountId)" }

    private func loadCollapsedNodeIDs(accountId: Int64) async {
        guard
            let raw = try? await store.metaValue(forKey: Self.collapsedKey(accountId: accountId)),
            let data = raw.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        collapsedNodeIDs[accountId] = Set(ids)
    }

    private func persistCollapsedNodeIDs(_ ids: Set<String>, accountId: Int64) {
        Task { [store] in
            let key = Self.collapsedKey(accountId: accountId)
            guard ids.isEmpty == false else {
                try? await store.setMetaValue(nil, forKey: key)
                return
            }
            guard let data = try? JSONEncoder().encode(Array(ids)), let json = String(data: data, encoding: .utf8)
            else { return }
            try? await store.setMetaValue(json, forKey: key)
        }
    }

    // MARK: - Actions

    // `refresh` and `markAllRead` are set by `RootSplitView`, which can reach the engine and
    // the triage actions. A plain `@Observable` store has no other route to either, and
    // closures keep `NCMailSync` out of this file, the same way `TriageContext` does it.
    //
    // `showStorage(_:)` and `signOut(_:)` only choose the Settings tab. The *view* opens
    // the window with `@Environment(\.openSettings)`, because AppKit's `showSettingsWindow:`
    // selector no longer opens a SwiftUI `Settings` scene: it logs "Please use SettingsLink
    // for opening the Settings scene" and does nothing (ADR-0062). Neither performs the
    // destructive action itself. The sidebar is not where a sign-out gets confirmed.

    /// Syncs one mailbox, or every mailbox of the account when `mailboxId` is nil.
    var refresh: (@MainActor (_ accountId: Int64, _ mailboxId: Int64?) -> Void)?
    /// Marks every message in one mailbox read, through the triage queue.
    var markAllRead: (@MainActor (_ mailboxId: Int64) -> Void)?

    func refreshAccount(_ account: AccountRecord) {
        refresh?(account.id, nil)
    }

    func showStorage(_ account: AccountRecord) {
        Self.logger.info("storage panel requested for account \(account.id, privacy: .public)")
        SettingsTab.preferredTab = .storage
    }

    func signOut(_ account: AccountRecord) {
        Self.logger.info("sign-out requested for account \(account.id, privacy: .public)")
        SettingsTab.preferredTab = .accounts
    }

    func refreshMailbox(accountId: Int64, mailboxId: Int64) {
        refresh?(accountId, mailboxId)
    }

    func markAllRead(accountId: Int64, mailboxId: Int64) {
        markAllRead?(mailboxId)
    }

    /// Opens the Get info panel. The view presents on `infoTarget` and clears it on dismiss.
    func getInfo(accountId: Int64, mailboxId: Int64) {
        infoTarget = MailboxInfoTarget(accountId: accountId, mailboxId: mailboxId)
    }

    /// The panel's model, built here because this store is what holds the `MailStore`; the
    /// panel reads the mirror and nothing else.
    func infoModel(for target: MailboxInfoTarget) -> MailboxInfoModel {
        MailboxInfoModel(target: target, store: store)
    }
}
