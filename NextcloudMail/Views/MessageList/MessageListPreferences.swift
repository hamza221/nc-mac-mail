// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// The web client's `layout-mode`, spelled as it saves it (`AppSettingsMenu.vue`).
enum MessageListLayout: String, CaseIterable, Identifiable, Sendable {
    case verticalSplit = "vertical-split"
    case horizontalSplit = "horizontal-split"
    case list = "no-split"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verticalSplit: String(localized: "Vertical split")
        case .horizontalSplit: String(localized: "Horizontal split")
        case .list: String(localized: "List")
        }
    }
}

/// The server preferences that shape the message list, parsed from the mirrored
/// `preference` rows with the web client's defaults for a key never set (`null`).
struct MessageListPreferences: Equatable, Sendable {
    static let layoutKey = "layout-mode"
    static let compactKey = "compact-mode"
    static let sortOrderKey = "sort-order"
    static let favoritesKey = "sort-favorites"
    static let followUpKey = "follow-up-reminders"
    static let keys = [layoutKey, compactKey, sortOrderKey, favoritesKey, followUpKey]

    var layout: MessageListLayout = .verticalSplit
    var isCompact = false
    var sortOrder: MessageSortOrder = .newest
    /// `sort-favorites`: starred messages in their own section at the top.
    var favoritesOnTop = false
    /// `follow-up-reminders`, on unless set to `false`, as the web reads it.
    var followUpReminders = true

    init() {}

    /// Values by key; a missing key, a null and a value this version does not know all mean
    /// the default, because a newer web client writing a new layout must not break this one.
    init(values: [String: String]) {
        layout = values[Self.layoutKey].flatMap(MessageListLayout.init(rawValue:)) ?? .verticalSplit
        isCompact = values[Self.compactKey] == "true"
        sortOrder = values[Self.sortOrderKey].flatMap(MessageSortOrder.init(rawValue:)) ?? .newest
        favoritesOnTop = values[Self.favoritesKey] == "true"
        followUpReminders = values[Self.followUpKey] != "false"
    }

    /// The part of the preferences that changes which rows are queried. Layout and compact
    /// mode only change how they are drawn.
    var querying: Querying {
        Querying(sortOrder: sortOrder, favoritesOnTop: favoritesOnTop, followUpReminders: followUpReminders)
    }

    struct Querying: Equatable, Sendable {
        var sortOrder: MessageSortOrder = .newest
        var favoritesOnTop = false
        var followUpReminders = true
    }
}

extension MessageListPreferences {
    init(_ querying: Querying) {
        self.init()
        sortOrder = querying.sortOrder
        favoritesOnTop = querying.favoritesOnTop
        followUpReminders = querying.followUpReminders
    }
}

/// The list preferences, live, and the one way to change them.
///
/// Read from the first signed-in login (the lowest login id): one window has one layout, and
/// the first login is the stable choice across launches. Written to **every** login through
/// the queue's `setPreference` kind, so each server's web client agrees and the change
/// survives being offline; the queue applies the row locally in the same transaction, which
/// is how the observation below sees the change at once. Sort order in particular is never
/// kept locally — the mirror's cursor semantics follow the server's value (ADR-0036).
@MainActor
@Observable
final class MessageListPreferenceStore {
    private(set) var preferences = MessageListPreferences()

    /// The queue for one account. `AccountEngine.mutationQueue(accountId:)` in the app; a bare
    /// queue over the same store in tests.
    private let queue: @MainActor (Int64) -> MutationQueue
    private let store: MailStore
    private var loginId: Int64?
    private var values: [String: String] = [:]
    private var accountsObservation: Task<Void, Never>?
    private var valueObservations: [Task<Void, Never>] = []

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "message-list")

    init(store: MailStore, queue: @escaping @MainActor (Int64) -> MutationQueue) {
        self.store = store
        self.queue = queue
    }

    /// Follows the account rows, because a sign-in or sign-out can change which login is
    /// first. Safe to call more than once.
    func start() {
        guard accountsObservation == nil else { return }
        let store = store
        accountsObservation = Task { [weak self] in
            do {
                for try await _ in store.observeAccounts() {
                    let first = try await store.logins().compactMap(\.id).min()
                    self?.follow(loginId: first)
                }
            } catch {
                Self.logger.error(
                    "preference login observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        accountsObservation?.cancel()
        accountsObservation = nil
        follow(loginId: nil)
    }

    func set(layout: MessageListLayout) async { await write(MessageListPreferences.layoutKey, layout.rawValue) }
    func set(isCompact: Bool) async { await write(MessageListPreferences.compactKey, String(isCompact)) }
    func set(sortOrder: MessageSortOrder) async { await write(MessageListPreferences.sortOrderKey, sortOrder.rawValue) }
    func set(favoritesOnTop: Bool) async { await write(MessageListPreferences.favoritesKey, String(favoritesOnTop)) }

    /// Queues `key = value` for every login whose mirrored value differs. A login already
    /// holding the value is left alone, as the web client does.
    func write(_ key: String, _ value: String) async {
        do {
            for login in try await store.logins() {
                guard let loginId = login.id,
                    let accountId = try await store.accounts(identity: login.identity).map(\.id).min()
                else { continue }
                guard try await store.preferenceValue(key: key, loginId: loginId) != value else { continue }
                try await queue(accountId).perform(.setPreference(key: key, value: value), loginId: loginId)
            }
        } catch {
            Self.logger.error("could not queue a list preference: \(String(describing: error), privacy: .public)")
        }
    }

    private func follow(loginId newLoginId: Int64?) {
        guard newLoginId != loginId else { return }
        loginId = newLoginId
        valueObservations.forEach { $0.cancel() }
        valueObservations = []
        values = [:]
        preferences = MessageListPreferences()
        guard let newLoginId else { return }
        let store = store
        valueObservations = MessageListPreferences.keys.map { key in
            Task { [weak self] in
                do {
                    for try await value in store.observePreferenceValue(key: key, loginId: newLoginId) {
                        self?.receive(key: key, value: value)
                    }
                } catch {
                    Self.logger.error("preference observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func receive(key: String, value: String?) {
        values[key] = value
        let parsed = MessageListPreferences(values: values)
        if parsed != preferences { preferences = parsed }
    }
}
