// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog
import SwiftUI

/// What the sidebar has selected and how the list is drawn, kept for a relaunch rather than a
/// settings screen — [ux-spec.md](../../docs/product/ux-spec.md#window) is explicit that this
/// is restoration, not a preference.
///
/// The sidebar writes ``selection``, the columns route on it, and ``mailboxDidChange``
/// carries the mailbox it names on to every `SyncScheduler`: the mailbox being read syncs on
/// the shorter foreground interval and is never deep-reconciled underneath the scroll view.
///
/// Two restorations, in order
/// ([ADR-0084](../../docs/decisions/0084-the-shell-starts-logins-before-accounts.md)): the
/// selection this Mac saved, exactly; failing that, the server's `start-mailbox-id`, which
/// ``startMailboxDidSettle`` keeps up to date after ``StartMailbox/settleDelay`` on one
/// selection, as the web client does.
@MainActor
@Observable
final class NavigationState {
    private(set) var selection: SidebarSelection?
    private(set) var listView: ListView = .threaded

    /// The mailbox the v1 message list shows. Nil for every other selection.
    var selectedMailboxID: Int64? { selection?.mailboxId }

    /// Called with every selection's mailbox, including the one `load()` restores.
    /// `AppSession` sets it so that the sync engine hears about a selection without a view
    /// having to reach for a scheduler.
    var mailboxDidChange: (@MainActor (Int64?) -> Void)?
    /// A launch with nothing saved locally asks for the server's start mailbox.
    var startMailbox: (@MainActor () async -> SidebarSelection?)?
    /// A start-mailbox candidate stood for ``StartMailbox/settleDelay``.
    var startMailboxDidSettle: (@MainActor (SidebarSelection) async -> Void)?

    private let store: MailStore
    private let settleDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var settleTask: Task<Void, Never>?

    private enum MetaKey {
        static let selection = "navigation.selection"
        static let listView = "navigation.listView"
        /// v1's mailbox-only selection, read once into ``selection`` and then deleted.
        static let legacyMailbox = "navigation.selectedMailboxId"
    }

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "navigation")

    /// - Parameter sleep: how the settle delay waits; a test passes one it controls.
    init(
        store: MailStore,
        settleDelay: Duration = StartMailbox.settleDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.settleDelay = settleDelay
        self.sleep = sleep
    }

    /// Reads what was persisted the last time any of the setters below ran, or the server's
    /// start mailbox when this Mac saved no selection. Safe to call more than once; each read
    /// is independent of the others.
    ///
    /// A restored selection does not start the settle timer: it is where the user already
    /// was, not a new choice.
    func load() async {
        selection = await savedSelection()
        if selection == nil, let startMailbox {
            selection = await startMailbox()
        }
        if let raw = try? await store.metaValue(forKey: MetaKey.listView), let value = ListView(rawValue: raw) {
            listView = value
        }
        mailboxDidChange?(selectedMailboxID)
    }

    func select(_ newSelection: SidebarSelection?) {
        guard newSelection != selection else { return }
        selection = newSelection
        mailboxDidChange?(selectedMailboxID)
        persist(newSelection)
        scheduleStartMailbox(newSelection)
    }

    /// The v1 sidebar's binding, which only knows mailboxes.
    func selectMailbox(_ id: Int64?) {
        select(id.map(SidebarSelection.mailbox))
    }

    func setListView(_ value: ListView) {
        listView = value
        Task { try? await store.setMetaValue(value.rawValue, forKey: MetaKey.listView) }
    }

    // MARK: - Persistence

    private func savedSelection() async -> SidebarSelection? {
        guard let raw = try? await store.metaValue(forKey: MetaKey.selection) else {
            return await migratedSelection()
        }
        do {
            return try JSONDecoder().decode(SidebarSelection.self, from: Data(raw.utf8))
        } catch {
            // A selection this version cannot read — written by a newer one — is no
            // selection, not a failed launch.
            Self.logger.info("saved selection unreadable; ignoring it")
            return nil
        }
    }

    /// v1 saved only a mailbox id. Read once, rewritten under the new key, and removed.
    private func migratedSelection() async -> SidebarSelection? {
        guard let raw = try? await store.metaValue(forKey: MetaKey.legacyMailbox) else { return nil }
        let selection = Int64(raw).map(SidebarSelection.mailbox)
        try? await store.setMetaValue(nil, forKey: MetaKey.legacyMailbox)
        if selection != nil { persist(selection) }
        return selection
    }

    private func persist(_ selection: SidebarSelection?) {
        let raw = selection.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        Task { try? await store.setMetaValue(raw, forKey: MetaKey.selection) }
    }

    /// Restarts the settle timer on every change, so only a selection the user stays on is
    /// saved; one that is not a candidate just cancels it.
    private func scheduleStartMailbox(_ selection: SidebarSelection?) {
        settleTask?.cancel()
        settleTask = nil
        guard let selection, StartMailbox.isCandidate(selection) else { return }
        let delay = settleDelay
        let sleep = sleep
        settleTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.selection == selection else { return }
            await startMailboxDidSettle?(selection)
        }
    }
}
