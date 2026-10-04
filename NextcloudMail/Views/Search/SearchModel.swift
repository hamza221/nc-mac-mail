// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog
import Observation

/// What is in the search field, what it is scoped to, and how much of the mirror it can see.
///
/// One object rather than three `@State` values, because the menu-bar commands need to reach
/// the same field the view draws: ⌘F focuses it and ⌘⇧F widens the scope, and a `Commands`
/// struct is built outside the window's view tree with no `@FocusState` to reach into.
///
/// Nothing here touches the network. The scope control and the coverage counter are both
/// reads of the mirror, which is the whole of what search is
/// ([ADR-0011](../../../docs/decisions/0011-fts5-standalone-index.md)).
@MainActor
@Observable
final class SearchModel {
    /// Exactly what is in the field. Never pre-escaped: the translation to FTS5 syntax
    /// happens in the store, once, at the last possible moment.
    var text = ""

    /// The chips and the sheet's toggles. Shared, so "Has attachment" is one switch whether
    /// it was flipped in the bar or in the sheet.
    var flags = SearchQuery.FlagFilter()

    /// The sheet's valued fields, as last applied with its Search button.
    var parameters = SearchQuery.Parameters()

    /// Whether the "Search parameters" sheet is up.
    var isParametersSheetPresented = false

    var scope: MessageListFilter.Scope = .mailbox {
        didSet {
            guard scope != oldValue else { return }
            observeCoverage()
        }
    }

    /// The mailbox the list is showing, which is what `.mailbox` scope means. Assigned by the
    /// view from `NavigationState` rather than read here, so this object needs no navigation.
    var mailboxId: Int64? {
        didSet {
            guard mailboxId != oldValue else { return }
            observeCoverage()
        }
    }

    /// How much of the scope is searchable. Nil until the first value arrives.
    private(set) var coverage: SearchCoverage?

    /// Bumped by ⌘F and ⌘⇧F. The view watches it and moves focus, which is the only way a
    /// `Commands` struct can reach a `@FocusState` inside a window.
    private(set) var focusRequests = 0

    private let store: MailStore
    private var coverageObservation: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "search")

    init(store: MailStore) {
        self.store = store
    }

    // MARK: - What the list shows

    /// The narrowing to hand the message list, or nil for the ordinary mailbox.
    ///
    /// Nil whenever the query has nothing to search for — a blank field, whitespace, or a
    /// single character, with no filter on — so clearing the field with the space bar held
    /// down, or typing the first letter, leaves the mailbox showing rather than an empty
    /// screen. A filter on its own is a search.
    var filter: MessageListFilter? {
        let query = query
        guard query.hasCriteria else { return nil }
        return MessageListFilter(
            query: text.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope, search: query)
    }

    var isSearching: Bool { filter != nil }

    /// The store's query for the field, the chips and the sheet right now.
    var query: SearchQuery {
        SearchQuery(text: text, scope: storeScope, flags: flags.isEmpty ? nil : flags, parameters: parameters)
    }

    // MARK: - Filters

    /// Whether any chip, toggle or parameter is on — what keeps the filter bar on screen
    /// after the field is cleared.
    var hasActiveFilters: Bool { !flags.isEmpty || !parameters.isEmpty }

    /// How many of the sheet's fields are set, for the button's label. The three chips are
    /// visible in the bar already and are not counted again, except where the sheet shares
    /// one ("Has attachments").
    var activeParameterCount: Int {
        let p = parameters
        let fields: [Bool] = [
            !p.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !p.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            p.sentAfter != nil || p.sentBefore != nil,
            p.from.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false,
            !p.to.isEmpty, !p.cc.isEmpty, !p.bcc.isEmpty, !p.tags.isEmpty,
            flags.importantOnly, flags.starredOnly, flags.mentionsMeOnly,
        ]
        return fields.count(where: { $0 })
    }

    /// The Clear button: every chip, toggle and parameter off. The text is left alone —
    /// Escape is what clears that.
    func clearFilters() {
        flags = SearchQuery.FlagFilter()
        parameters = SearchQuery.Parameters()
    }

    /// The sheet's Search button: its draft becomes the query in one assignment, so the
    /// list reopens its observation once rather than once per field.
    func apply(parameters newParameters: SearchQuery.Parameters, flags newFlags: SearchQuery.FlagFilter) {
        parameters = newParameters
        flags = newFlags
        isParametersSheetPresented = false
    }

    /// The tags the sheet offers for the current scope, live.
    func tagOptions() -> StoreObservation<[SearchTagOption]> {
        store.observeSearchTags(scope: storeScope)
    }

    /// Addresses seen in mirrored mail starting with `prefix`, for the address fields.
    /// Empty on failure: a suggestion list is a convenience, and the field still accepts
    /// whatever is typed.
    func addressSuggestions(for prefix: String) async -> [SearchAddressSuggestion] {
        do {
            return try await store.searchAddressSuggestions(prefix: prefix)
        } catch {
            Self.logger.error("address suggestions failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// The message list's window, opened on the search instead of the mailbox.
    ///
    /// Installed once into `MessageListStore.filteredSource` and then left alone. It reads
    /// ``query`` when the list calls it rather than capturing one, so extending the window
    /// mid-query and typing the next character both open the observation the field currently
    /// describes — and there is no ordering to get wrong between installing a closure and the
    /// list asking for rows.
    ///
    /// `self` is captured strongly and that is not a leak: this object never refers to the
    /// list store, so the only reference runs one way and both die with the window.
    func rowSource() -> MessageRowSource {
        { [self] range in store.observeSearchRows(query, range: range) }
    }

    // MARK: - Scope

    private var storeScope: SearchQuery.Scope {
        switch scope {
        case .mailbox: mailboxId.map { .mailbox($0) } ?? .all
        case .allMail: .all
        }
    }

    /// ⌘⇧F. Widens the scope and puts the caret in the field, in that order, so the first
    /// character typed is already searching everything.
    func searchAllMail() {
        scope = .allMail
        requestFocus()
    }

    /// ⌘F.
    func requestFocus() {
        focusRequests += 1
    }

    // MARK: - Coverage

    /// Starts watching the coverage counts, replacing whatever was being watched before.
    ///
    /// Live rather than read once, because the footer's whole job is to be honest *during*
    /// the backfill: the numbers climb while it runs and the footer takes itself off screen
    /// when they meet.
    func observeCoverage() {
        coverageObservation?.cancel()
        let scope = storeScope
        coverageObservation = Task { [weak self] in
            guard let store = self?.store else { return }
            do {
                for try await fresh in store.observeSearchCoverage(scope: scope) {
                    self?.coverage = fresh
                }
            } catch {
                Self.logger.error("coverage observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        coverageObservation?.cancel()
        coverageObservation = nil
    }

    // MARK: - What the footer says

    /// "Searching 31,204 of 48,902 downloaded messages.", or nil when there is nothing to
    /// admit to.
    ///
    /// Nil while no search is running, and nil once the backfill is done — the footer takes
    /// itself off screen rather than waiting to be dismissed. What it removes while it is
    /// there is the worst failure search has: a confident empty result over a partial index.
    var coverageSummary: String? {
        guard isSearching, let coverage, !coverage.isComplete else { return nil }
        return String(
            localized: """
                Searching \(coverage.indexedMessages.formatted()) of \
                \(coverage.totalMessages.formatted()) downloaded messages.
                """
        )
    }

    /// What "All Mail" leaves out, and only when it leaves something out.
    ///
    /// Unsubscribed mailboxes are not mirrored
    /// ([ADR-0007](../../../docs/decisions/0007-subscribed-mailboxes-only.md)), so searching
    /// everything searches everything downloaded. Saying that unprompted on every account
    /// would be noise; saying nothing when a folder really is missing would be a lie.
    var unmirroredSummary: String? {
        guard isSearching, scope == .allMail, let count = coverage?.unmirroredMailboxes, count > 0 else {
            return nil
        }
        if count == 1 {
            return String(localized: "One mailbox is not downloaded, so it is not searched.")
        }
        return String(localized: "\(count.formatted()) mailboxes are not downloaded, so they are not searched.")
    }
}
