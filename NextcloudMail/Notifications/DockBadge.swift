// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailStore
import OSLog

/// The Dock icon's badge: unread messages over every account's inbox.
///
/// Each account's count is `observeMailboxes(accountId:)`'s inbox row, which is the sidebar's
/// number exactly — local once the inbox is fully enumerated, the server's until then
/// (ADR-0060) — so the badge and the sidebar never disagree.
@MainActor
final class DockBadge {
    var setLabel: @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }

    private let store: MailStore
    private var unread: [Int64: Int] = [:]
    private var accounts: [Int64: Task<Void, Never>] = [:]
    private var observation: Task<Void, Never>?
    private var shown: String??

    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "notifications")

    init(store: MailStore) {
        self.store = store
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self, store] in
            do {
                for try await rows in store.observeAccounts() {
                    self?.watch(accountIds: rows.map(\.id))
                }
            } catch {
                Self.logger.error("badge observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        for task in accounts.values { task.cancel() }
        accounts.removeAll()
    }

    /// Nil, not "0", clears the badge.
    nonisolated static func label(unread: some Sequence<Int>) -> String? {
        let total = unread.reduce(0, +)
        return total > 0 ? String(total) : nil
    }

    /// An account's inbox unread count from its mailbox rows. An account without a selectable
    /// inbox (still being discovered) counts nothing.
    nonisolated static func inboxUnread(_ mailboxes: [MailboxRecord]) -> Int {
        mailboxes.filter { $0.specialRole == "inbox" && $0.isSelectable }.reduce(0) { $0 + $1.unreadCount }
    }

    private func watch(accountIds: [Int64]) {
        let wanted = Set(accountIds)
        for (id, task) in accounts where !wanted.contains(id) {
            task.cancel()
            accounts[id] = nil
            unread[id] = nil
        }
        for id in accountIds where accounts[id] == nil {
            accounts[id] = Task { [weak self, store] in
                do {
                    for try await mailboxes in store.observeMailboxes(accountId: id) {
                        self?.update(accountId: id, count: Self.inboxUnread(mailboxes))
                    }
                } catch {
                    Self.logger.error(
                        "badge account observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        }
        refresh()
    }

    private func update(accountId: Int64, count: Int) {
        guard accounts[accountId] != nil else { return }
        unread[accountId] = count
        refresh()
    }

    private func refresh() {
        let label = Self.label(unread: unread.values)
        guard shown != .some(label) else { return }
        shown = .some(label)
        setLabel(label)
    }
}
