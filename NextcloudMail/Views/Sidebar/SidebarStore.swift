// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
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

    // Every method below is a hook, not an implementation: the sidebar's context menus
    // (ux-spec.md#sidebar) name these five actions, and nothing in the app yet has anything
    // for them to do. No `MirrorCoordinator` or `SyncScheduler` is wired into `AppSession` --
    // account rows exist only once something calls
    // `MirrorCoordinator.discoverAccounts(store:client:identity:)` per Keychain entry, which
    // is not this workstream's file to add (see the report). "Mark all as read" is a triage
    // action and belongs to WS-10's `Actions/**`. Logging rather than silently doing nothing
    // means a click is visible in the console during manual testing instead of looking like
    // a dead button.
    //
    // `showStorage(_:)` and `signOut(_:)` are the two WS-12's brief names as its own, even
    // though this file is WS-07's. They open the real Settings window WS-12 built, on the
    // tab that has something to do about the account: Storage's panel, or the Accounts
    // tab's confirmed Sign Out button. Neither performs the destructive action itself. The
    // sidebar is not where a sign-out gets confirmed.

    func refreshAccount(_ account: AccountRecord) {
        Self.logger.info("refresh requested for account \(account.id, privacy: .public); no SyncScheduler wired yet")
    }

    func showStorage(_ account: AccountRecord) {
        Self.logger.info("storage panel requested for account \(account.id, privacy: .public)")
        openSettings(on: .storage)
    }

    func signOut(_ account: AccountRecord) {
        Self.logger.info("sign-out requested for account \(account.id, privacy: .public)")
        openSettings(on: .accounts)
    }

    /// `SettingsTab` is `NextcloudMail/Views/Settings/SettingsScene.swift`'s type, in the same
    /// app target, so no import is needed to name it here, only the courtesy of saying so.
    /// There is no `@Environment(\.openSettings)` to reach for: `SidebarStore` is a plain
    /// `@Observable`, not a `View`. This goes straight to the AppKit selector the
    /// "Settings…" menu item itself sends.
    private func openSettings(on tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.preferredTabKey)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func refreshMailbox(accountId: Int64, mailboxId: Int64) {
        Self.logger.info("refresh requested for mailbox \(mailboxId, privacy: .public); no SyncScheduler wired yet")
    }

    func markAllRead(accountId: Int64, mailboxId: Int64) {
        Self.logger.info("mark-all-read requested for mailbox \(mailboxId, privacy: .public); WS-10 owns it")
    }

    func getInfo(accountId: Int64, mailboxId: Int64) {
        Self.logger.info("get-info requested for mailbox \(mailboxId, privacy: .public); no view owns it yet")
    }
}
