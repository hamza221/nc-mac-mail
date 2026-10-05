// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NCMailSync
import OSLog
import Observation
import SwiftUI

/// A narrowing of the list. WS-11 builds one; this workstream only renders what it selects.
///
/// It carries no SQL: the search owns its query and installs it as
/// ``MessageListStore/filteredSource``. Setting a filter without that source yields an empty
/// list and the no-results screen rather than the unfiltered mailbox, because showing every
/// message under a query someone typed is the worse of the two wrong answers.
struct MessageListFilter: Equatable, Sendable {
    /// [ux-spec.md](../../../docs/product/ux-spec.md#search) gives search two scopes.
    enum Scope: String, Equatable, Sendable {
        case mailbox
        case allMail
    }

    var query: String
    var scope: Scope
    /// The structured search behind the text, for identity only: chips and the parameters
    /// sheet change the search without changing ``query``, and the list reopens its
    /// observation only when the filter changes.
    var search: SearchQuery?

    init(query: String, scope: Scope = .mailbox, search: SearchQuery? = nil) {
        self.query = query
        self.scope = scope
        self.search = search
    }
}

/// One window of rows, as a live query.
///
/// A closure rather than a protocol: search is the same list over a different query, and the
/// only thing that changes is which observation the window is opened on.
typealias MessageRowSource = (Range<Int>) -> StoreObservation<[MessageRow]>

/// What fills the column when there are no rows to draw.
///
/// The cases are [ux-spec.md](../../../docs/product/ux-spec.md#message-list)'s states, and
/// none of them is a spinner. A mailbox that is still filling shows the rows it has; a
/// mailbox with none yet says what is happening in words, because a spinner over a local
/// database is a promise about the network.
enum MessageListPresentation: Equatable {
    /// Draw the list. Also the answer for the frame or two before the first delivery, so
    /// selecting a mirrored mailbox never flashes "downloading" on its way to the rows.
    case rows
    case noMailboxSelected
    /// Envelopes are still arriving and none have landed in this mailbox yet.
    case mirroring
    case emptyMailbox
    case noResults(String)
    /// Never mirrored and no route to the server.
    case notDownloaded
}

/// The message list's rows, its sections, its windows and its selection.
///
/// Nothing here reaches the network. `MailStore` cannot see `NCMailNet`, so that is a fact
/// about the link line rather than a convention, and the list is identical with the network
/// off ([overview.md](../../../docs/architecture/overview.md#the-invariant)). The one
/// network-backed answer the list shows — whether a follow-up was answered — is asked for
/// through ``followUpCheck`` and arrives as `serverResult` rows like everything else.
///
/// A list is one or more *plans* (``MessageListPlan``): Priority inbox is four live queries,
/// a mailbox with favorites on top is two. Each has its own window, so scrolling one section
/// does not re-read the others. Every observation is *replaced* rather than added to when the
/// selection changes; cancelling the `Task` is enough, because dropping the iterator cancels
/// the database observation
/// ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
///
/// The selection lives here and not in a view, which is what lets the window change layout
/// — three columns, two, or the list alone — without losing it: the views come and go
/// through ``attach()``/``detach()``, and only the observations stop in between.
@MainActor
@Observable
final class MessageListStore {
    /// Every row on screen, in on-screen order: the sections, concatenated. What triage,
    /// `←`/`→` and `⌘A` act on.
    private(set) var rows: [MessageRow] = []
    /// `rows` in their sections, computed once per delivery rather than once per redraw.
    private(set) var sections: [MessageListSection] = []
    /// The mailbox behind a single-mailbox list, live, for the mirror state.
    private(set) var mailbox: MailboxRecord?
    private(set) var source: MessageListSource?

    /// The tags on each visible row, read in one query for the window.
    private(set) var tags: [Int64: [TagRecord]] = [:]
    /// Each visible row's named attachments, for the chips.
    private(set) var attachments: [Int64: [AttachmentChip]] = [:]
    /// Cached AI thread summaries (`serverResult` kind `threadSummary`) for visible rows.
    private(set) var summaries: [Int64: String] = [:]
    /// Follow-up rows whose reply has arrived; hidden before the tag removal lands.
    private(set) var followedUp: Set<Int64> = []

    /// The selected rows' local ids.
    var selection: Set<Int64> = []
    /// The message opened in place in the list layout, where there is no detail column.
    var openedMessageId: Int64?

    /// Whether the app has a route. Assigned by the view from `AppStatus`, because being
    /// offline changes what an empty mailbox means and nothing else about this type.
    var isOffline = false

    /// Installed by WS-11 when a search is running. Absent, a filter shows no results.
    var filteredSource: MessageRowSource?

    /// Asks the server whether the Follow up rows were answered. The shell wires it to each
    /// login's `ServerStateMirror.checkFollowUps(messageIds:)`.
    var followUpCheck: (@MainActor ([MessageRow]) -> Void)?

    /// Two screens at a typical window height, so the first scroll gesture does not extend
    /// the window and the measured first frame covers more than what is visible.
    static let initialWindow = 60
    /// Four more screens per extension. Large enough that a fast flick does not walk the
    /// window forward one screen at a time, small enough that the query stays a seek.
    static let windowStep = 120

    private struct PlanState {
        let plan: MessageListPlan
        var windowSize = MessageListStore.initialWindow
        var rows: [MessageRow] = []
        var hasDelivered = false
        var hasMore = true
        var task: Task<Void, Never>?
    }

    private let store: MailStore
    private var listView: ListView = .threaded
    private var filter: MessageListFilter?
    private var preferences = MessageListPreferences.Querying()
    private var inboxIds: [Int64] = []
    /// False until the first Inbox list arrives, so a merged list does not flash "empty".
    private var hasInboxIds = false
    private var plans: [PlanState] = []
    private var mailboxObservation: Task<Void, Never>?
    private var inboxObservation: Task<Void, Never>?
    private var adornmentObservations: [Task<Void, Never>] = []
    private var adornedIds: [Int64] = []
    private var checkedFollowUps: Set<Int64> = []
    /// Views showing this list right now; see ``attach()``.
    private var attachedViews = 0
    private var isRunning = false
    private let now: @Sendable () -> Date

    /// Identifiers and counts only. A subject or an address in this log would be the same
    /// leak as one in a crash report.
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "message-list")

    init(store: MailStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    // MARK: - What is on screen

    var presentation: MessageListPresentation {
        if !rows.isEmpty { return .rows }
        if let filter { return .noResults(filter.query) }
        guard let source else { return .noMailboxSelected }
        // Before the first answer the list is blank, not "empty": the database answers in
        // milliseconds and a flash of "No messages" on every selection is a lie.
        guard plans.allSatisfy(\.hasDelivered), !source.needsInboxes || hasInboxIds else { return .rows }
        guard source.mailboxId != nil else { return .emptyMailbox }
        guard let mailbox else { return .rows }
        if mailbox.envelopesComplete { return .emptyMailbox }
        return isOffline ? .notDownloaded : .mirroring
    }

    var hasMore: Bool { plans.contains(where: \.hasMore) }

    /// The brief's `isMirroring`, computed from the mailbox row rather than tracked, so it
    /// cannot disagree with the database that produced it.
    var isMirroring: Bool {
        mailbox.map { !$0.envelopesComplete } ?? false
    }

    var title: String {
        source?.title ?? mailbox?.displayName ?? String(localized: "Messages")
    }

    /// The selected rows, for triage to act on.
    ///
    /// Filtered against the windows, so a row selected and then pushed past a window's end
    /// by newly arrived mail is not in here. That is deliberate rather than pruned: dropping
    /// it from ``selection`` would silently deselect something the user selected.
    var selectedRows: [MessageRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// The one message the detail column shows, or nil for none and for a multi-selection.
    var focusedMessageId: Int64? {
        selection.count == 1 ? selection.first : nil
    }

    /// The account of the focused message, which picks the detail column's services. In a
    /// merged list it is the row's own account, not the (absent) selected mailbox's.
    var focusedAccountId: Int64? {
        guard let id = focusedMessageId else { return mailbox?.accountId }
        return rows.first(where: { $0.id == id })?.accountId ?? mailbox?.accountId
    }

    /// The sender's picture for one row, read from the mirror.
    func avatarLoader(for email: String?) -> (@Sendable () async throws -> Image)? {
        store.avatarLoader(for: email)
    }

    /// `⌘A`: every loaded row of every section.
    func selectAll() {
        selection = Set(rows.map(\.id))
    }

    /// What dragging `row` carries: the selection when the row is part of it, else the row
    /// alone. A move is one mailbox's operation, so a selection spanning mailboxes drags the
    /// rows sharing the dragged row's mailbox.
    func dragPayload(for row: MessageRow) -> MessageDragPayload {
        let ids: [Int64] =
            selection.contains(row.id)
            ? rows.filter { selection.contains($0.id) && $0.mailboxId == row.mailboxId }.map(\.id)
            : [row.id]
        return MessageDragPayload(messageIds: ids, sourceMailboxId: row.mailboxId, accountId: row.accountId)
    }

    /// The tags a row shows as chips: not `$label1` (Important has its own glyph), not the
    /// web client's hidden system labels, and not `$follow_up` inside Priority inbox, which
    /// has a section for it.
    func visibleTags(for row: MessageRow) -> [TagRecord] {
        (tags[row.id] ?? []).filter { tag in
            guard tag.imapLabel != "$label1", !Self.hiddenTagNames.contains(tag.displayName.lowercased()) else {
                return false
            }
            return source != .priorityInbox || tag.imapLabel != MessageListPlan.followUpLabel
        }
    }

    /// `src/components/tags.js` in the web client.
    private static let hiddenTagNames: Set<String> = [
        "forwarded", "hasattachment", "has_cal", "has cal", "hasnoattachment", "notjunk", "loadremoteimages",
        "unsubscribe newsletter",
    ]

    /// Everything a row draws beyond its envelope, from the window's batch reads.
    func adornments(for row: MessageRow) -> MessageRowAdornments {
        let preview = preview(for: row)
        return MessageRowAdornments(
            tags: visibleTags(for: row),
            attachments: attachments[row.id] ?? [],
            preview: preview?.text,
            previewIsSummary: preview?.isSummary ?? false
        )
    }

    /// The preview line: the server's AI summary when there is one, else the preview text.
    func preview(for row: MessageRow) -> (text: String, isSummary: Bool)? {
        if let summary = (row.summary ?? summaries[row.id])?.trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty
        {
            return (summary, true)
        }
        guard let text = row.previewText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return (text, false)
    }

    // MARK: - Showing a list

    /// Shows one list, replacing whatever was being observed before.
    ///
    /// A different source, grouping or filter is a different list and clears the selection.
    /// Different preferences (sort order, favorites on top, follow-ups) are the same list
    /// drawn differently and keep it. The same arguments again restart nothing — unless the
    /// observations were stopped, in which case they resume, selection intact.
    func show(
        _ newSource: MessageListSource?,
        view newView: ListView,
        filter newFilter: MessageListFilter? = nil,
        preferences newPreferences: MessageListPreferences.Querying = .init()
    ) {
        let isNewList = newSource != source || newView != listView || newFilter != filter
        guard isNewList || newPreferences != preferences || !isRunning else { return }
        let sourceChanged = newSource != source
        source = newSource
        listView = newView
        filter = newFilter
        preferences = newPreferences
        if isNewList {
            selection = []
            openedMessageId = nil
            checkedFollowUps = []
            for state in plans { state.task?.cancel() }
            plans = []
        }
        isRunning = true
        if sourceChanged || mailboxObservation == nil && inboxObservation == nil {
            observeSource()
        }
        replan()
    }

    /// Extends one section's window, or the last section's. No spinner and no page: the range
    /// stays anchored at zero and its upper bound grows, which keeps a row's position stable
    /// while sync writes underneath it.
    func loadMore(_ bucket: MessageListBucket? = nil) {
        guard
            let index = bucket.flatMap({ b in plans.firstIndex(where: { $0.plan.bucket == b }) }) ?? plans.indices.last
        else { return }
        guard plans[index].hasMore, plans[index].rows.count >= plans[index].windowSize else { return }
        plans[index].windowSize += Self.windowStep
        open(index)
    }

    /// Extends the window of the plan `row` ends, if it ends one. Called as rows appear.
    func rowAppeared(_ row: MessageRow) {
        guard let state = plans.first(where: { $0.rows.last?.id == row.id }) else { return }
        loadMore(state.plan.bucket)
    }

    /// A view showing this list appeared. Views come and go when the layout changes — and
    /// the new one can appear before the old one disappears — so the observations stop only
    /// when the last one has gone, and resume when one comes back.
    func attach() {
        attachedViews += 1
        guard attachedViews == 1, !isRunning, source != nil || filter != nil else { return }
        isRunning = true
        observeSource()
        replan()
    }

    func detach() {
        attachedViews = max(0, attachedViews - 1)
        if attachedViews == 0 { stop() }
    }

    /// Stops every observation. The rows, sections and selection stay as they were, so a
    /// view attaching again draws immediately and keeps what was selected.
    func stop() {
        isRunning = false
        for index in plans.indices {
            plans[index].task?.cancel()
            plans[index].task = nil
        }
        mailboxObservation?.cancel()
        mailboxObservation = nil
        inboxObservation?.cancel()
        inboxObservation = nil
        adornmentObservations.forEach { $0.cancel() }
        adornmentObservations = []
        adornedIds = []
    }

    // MARK: - Observation

    /// The single mailbox's row, or every account's Inbox ids, depending on the source.
    private func observeSource() {
        mailboxObservation?.cancel()
        mailboxObservation = nil
        inboxObservation?.cancel()
        inboxObservation = nil
        if source?.mailboxId != mailbox?.id { mailbox = nil }
        let store = store
        if let mailboxId = source?.mailboxId {
            mailboxObservation = Task { [weak self] in
                do {
                    for try await record in store.observeMailbox(id: mailboxId) {
                        self?.mailbox = record
                    }
                } catch {
                    Self.logger.error("mailbox observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if source?.needsInboxes == true {
            inboxObservation = Task { [weak self] in
                do {
                    for try await ids in store.observeInboxMailboxIds() {
                        guard let self else { return }
                        let changed = ids != inboxIds || !hasInboxIds
                        inboxIds = ids
                        hasInboxIds = true
                        if changed { replan() }
                    }
                } catch {
                    Self.logger.error("inbox observation stopped: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Rebuilds the plans from the source and preferences and opens each one's window.
    private func replan() {
        for state in plans { state.task?.cancel() }
        let newPlans: [MessageListPlan]
        if filter != nil {
            newPlans = [
                MessageListPlan(bucket: .all, query: MessageListQuery(mailboxIds: []), isDateGrouped: true)
            ]
        } else if let source {
            newPlans = MessageListPlan.plans(
                for: source,
                inboxIds: inboxIds,
                preferences: MessageListPreferences(preferences),
                now: Int64(now().timeIntervalSince1970)
            )
        } else {
            newPlans = []
        }
        // A plan that survives a replan keeps its rows and window, so changing an unrelated
        // preference, or a view attaching again, redraws nothing until the new answer lands.
        let previous = plans
        plans = newPlans.map { plan in
            guard var kept = previous.first(where: { $0.plan == plan }) else { return PlanState(plan: plan) }
            kept.task = nil
            return kept
        }
        rebuild()
        guard isRunning else { return }
        for index in plans.indices { open(index) }
    }

    private func open(_ index: Int) {
        plans[index].task?.cancel()
        let plan = plans[index].plan
        let range = 0..<plans[index].windowSize
        guard let observation = observation(for: plan, range: range) else {
            plans[index].task = nil
            plans[index].rows = []
            plans[index].hasDelivered = true
            plans[index].hasMore = false
            rebuild()
            return
        }
        plans[index].task = Task { [weak self] in
            do {
                for try await fresh in observation {
                    guard let self else { return }
                    deliver(fresh, to: plan, filling: range)
                }
            } catch {
                Self.logger.error("row observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func observation(for plan: MessageListPlan, range: Range<Int>) -> StoreObservation<[MessageRow]>? {
        if filter != nil { return filteredSource?(range) }
        return store.observeMessages(query: plan.query, view: listView, order: preferences.sortOrder, range: range)
    }

    private func deliver(_ fresh: [MessageRow], to plan: MessageListPlan, filling range: Range<Int>) {
        guard let index = plans.firstIndex(where: { $0.plan == plan }) else { return }
        plans[index].rows = fresh
        plans[index].hasDelivered = true
        plans[index].hasMore = fresh.count >= range.upperBound
        rebuild()
        if plan.bucket == .followUp { checkFollowUps(fresh) }
    }

    /// Keeps `rows` and `sections` in step, so a view can never read one without the other.
    private func rebuild() {
        let date = now()
        var built: [MessageListSection] = []
        for state in plans {
            var rows = state.rows
            if state.plan.bucket == .followUp { rows.removeAll { followedUp.contains($0.id) } }
            if state.plan.isDateGrouped {
                built += MessageListSection.dateGrouped(
                    rows, bucket: state.plan.bucket, order: preferences.sortOrder, now: date)
            } else if !rows.isEmpty {
                built.append(MessageListSection(bucket: state.plan.bucket, rows: rows))
            }
        }
        sections = built
        rows = built.flatMap(\.rows)
        observeAdornments()
    }

    // MARK: - Adornments

    /// Tags, attachment names, cached summaries and follow-up answers for exactly the rows on
    /// screen, each as one batch query that follows the window.
    private func observeAdornments() {
        let ids = plans.flatMap { $0.rows.map(\.id) }
        guard isRunning, ids != adornedIds else { return }
        adornedIds = ids
        adornmentObservations.forEach { $0.cancel() }
        adornmentObservations = []
        guard !ids.isEmpty else {
            tags = [:]
            attachments = [:]
            summaries = [:]
            return
        }
        let store = store
        let keys = ids.map(ServerResultKind.messageKey)
        let followUpKeys = plans.filter { $0.plan.bucket == .followUp }.flatMap { $0.rows.map(\.id) }
            .map(ServerResultKind.messageKey)
        adornmentObservations = [
            observe(store.observeTags(messageIds: ids)) { $0.tags = $1 },
            observe(store.observeAttachmentChips(messageIds: ids)) { $0.attachments = $1 },
            observe(store.observeServerResults(kind: ServerResultKind.threadSummary.rawValue, keys: keys)) {
                $0.summaries = Self.summaries(from: $1)
            },
        ]
        if !followUpKeys.isEmpty {
            adornmentObservations.append(
                observe(store.observeServerResults(kind: ServerResultKind.followUp.rawValue, keys: followUpKeys)) {
                    let answered = Self.answeredFollowUps(from: $1)
                    guard answered != $0.followedUp else { return }
                    $0.followedUp = answered
                    $0.rebuild()
                })
        }
    }

    private func observe<Value: Sendable>(
        _ observation: StoreObservation<Value>,
        apply: @escaping @MainActor (MessageListStore, Value) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await value in observation {
                    guard let self else { return }
                    apply(self, value)
                }
            } catch {
                Self.logger.error("adornment observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Asks once per row per list, not per delivery: the answer arrives as a row and the
    /// rows are observed.
    private func checkFollowUps(_ rows: [MessageRow]) {
        let unchecked = rows.filter { !checkedFollowUps.contains($0.id) }
        guard !unchecked.isEmpty, let followUpCheck else { return }
        checkedFollowUps.formUnion(unchecked.map(\.id))
        followUpCheck(unchecked)
    }

    /// `threadSummary` rows hold `{"status":"ready","data":"…"}`; anything else has no text.
    nonisolated static func summaries(from results: [ServerResultRecord]) -> [Int64: String] {
        var summaries: [Int64: String] = [:]
        for result in results {
            guard let id = Int64(result.key),
                case .ready(let data)? = try? ServerResultPayload(payloadJSON: result.payloadJSON),
                let text = data.stringValue ?? data.objectValue?["summary"]?.stringValue,
                !text.isEmpty
            else { continue }
            summaries[id] = text
        }
        return summaries
    }

    /// `followUp` rows answered `{"wasFollowedUp": true}`.
    nonisolated static func answeredFollowUps(from results: [ServerResultRecord]) -> Set<Int64> {
        Set(
            results.compactMap { result in
                guard let id = Int64(result.key),
                    case .ready(let data)? = try? ServerResultPayload(payloadJSON: result.payloadJSON),
                    data.objectValue?["wasFollowedUp"] == .bool(true)
                else { return nil }
                return id
            })
    }
}
