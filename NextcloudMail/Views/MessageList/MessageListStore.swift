// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog
import Observation

/// A narrowing of the list. WS-11 builds one; this workstream only renders what it selects.
///
/// It carries no SQL, because `MailStore.observeMessages(mailboxId:view:range:)` takes a
/// mailbox, a view and a range and nothing else. Until WS-11 adds a filtered observation,
/// setting a filter without also installing ``MessageListStore/filteredSource`` yields an
/// empty list and the no-results screen rather than the unfiltered mailbox, because showing
/// every message under a query someone typed is the worse of the two wrong answers.
struct MessageListFilter: Equatable, Sendable {
    /// [ux-spec.md](../../../docs/product/ux-spec.md#search) gives search two scopes.
    enum Scope: String, Equatable, Sendable {
        case mailbox
        case allMail
    }

    var query: String
    var scope: Scope

    init(query: String, scope: Scope = .mailbox) {
        self.query = query
        self.scope = scope
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
    /// Draw the list. Also the answer for the frame or two before the mailbox row arrives,
    /// so selecting a mirrored mailbox never flashes "downloading" on its way to the rows.
    case rows
    case noMailboxSelected
    /// Envelopes are still arriving and none have landed in this mailbox yet.
    case mirroring
    case emptyMailbox
    case noResults(String)
    /// Never mirrored and no route to the server.
    case notDownloaded
}

/// The message list's rows, its window, and its selection.
///
/// Nothing here reaches the network. `MailStore` cannot see `NCMailNet`, so that is a fact
/// about the link line rather than a convention, and the list is identical with the network
/// off ([overview.md](../../../docs/architecture/overview.md#the-invariant)).
///
/// Two observations run at a time and both are *replaced* rather than added to when the
/// selection changes: the rows, and the mailbox row behind the mirror state. Cancelling the
/// `Task` is enough, because dropping the iterator terminates the stream and terminating the
/// stream cancels the database observation
/// ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
@MainActor
@Observable
final class MessageListStore {
    private(set) var rows: [MessageRow] = []
    /// `rows` grouped by date, computed once per delivery rather than once per redraw.
    private(set) var sections: [MessageListSection] = []
    /// The mailbox behind the list, live, for the mirror state. Nil until it is read back.
    private(set) var mailbox: MailboxRecord?
    /// False once a window comes back short, which is how the list knows it has the tail.
    private(set) var hasMore = true

    /// The selected rows' local ids. Read by WS-10, which builds its requests from
    /// ``selectedRows`` because a triage request takes the server's id (ADR-0033).
    var selection: Set<Int64> = []

    /// Whether the app has a route. Assigned by the view from `AppStatus`, because being
    /// offline changes what an empty mailbox means and nothing else about this type.
    var isOffline = false

    /// Installed by WS-11 when a search is running. Absent, a filter shows no results.
    var filteredSource: MessageRowSource?

    /// Two screens at a typical window height, so the first scroll gesture does not extend
    /// the window and the measured first frame covers more than what is visible.
    static let initialWindow = 60
    /// Four more screens per extension. Large enough that a fast flick does not walk the
    /// window forward one screen at a time, small enough that the query stays a seek.
    static let windowStep = 120

    private let store: MailStore
    private var mailboxId: Int64?
    private var listView: ListView = .threaded
    private var filter: MessageListFilter?
    private var windowSize = MessageListStore.initialWindow
    private var rowObservation: Task<Void, Never>?
    private var mailboxObservation: Task<Void, Never>?

    /// Identifiers and counts only. A subject or an address in this log would be the same
    /// leak as one in a crash report.
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "message-list")

    init(store: MailStore) {
        self.store = store
    }

    // MARK: - What is on screen

    var presentation: MessageListPresentation {
        if !rows.isEmpty { return .rows }
        if let filter { return .noResults(filter.query) }
        guard mailboxId != nil else { return .noMailboxSelected }
        guard let mailbox else { return .rows }
        if mailbox.envelopesComplete { return .emptyMailbox }
        return isOffline ? .notDownloaded : .mirroring
    }

    /// The brief's `isMirroring`, computed from the mailbox row rather than tracked, so it
    /// cannot disagree with the database that produced it.
    var isMirroring: Bool {
        mailbox.map { !$0.envelopesComplete } ?? false
    }

    /// The selected rows, for WS-10 to act on.
    ///
    /// Filtered against the window, so a row selected and then pushed past the window's end
    /// by newly arrived mail is not in here. That is deliberate rather than pruned: dropping
    /// it from ``selection`` would silently deselect something the user selected.
    var selectedRows: [MessageRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// The one message the detail column shows, or nil for none and for a multi-selection.
    ///
    /// `MessageView` owns its own observation of this id, so nothing here has to keep the
    /// selected row inside the window for the message to stay on screen.
    var focusedMessageId: Int64? {
        selection.count == 1 ? selection.first : nil
    }

    // MARK: - Selection

    /// Shows one mailbox, replacing whatever was being observed before.
    func show(mailbox newMailboxId: Int64?, view newView: ListView, filter newFilter: MessageListFilter? = nil) {
        guard newMailboxId != mailboxId || newView != listView || newFilter != filter else { return }
        mailboxId = newMailboxId
        listView = newView
        filter = newFilter
        windowSize = Self.initialWindow
        hasMore = true
        selection = []
        assign(rows: [])

        mailboxObservation?.cancel()
        mailboxObservation = nil
        mailbox = nil

        guard let newMailboxId else {
            rowObservation?.cancel()
            rowObservation = nil
            return
        }
        mailboxObservation = Task { [weak self] in await self?.observeMailbox(id: newMailboxId) }
        openWindow()
    }

    /// Extends the window. No spinner and no page: the range stays anchored at zero and its
    /// upper bound grows, which is what keeps a row's position stable while sync writes
    /// underneath it (WS-03's note: do not page with a moving lower bound).
    func loadMore() {
        guard hasMore, rows.count >= windowSize else { return }
        windowSize += Self.windowStep
        openWindow()
    }

    /// Stops both observations. The view calls this when the column goes away.
    func stop() {
        rowObservation?.cancel()
        rowObservation = nil
        mailboxObservation?.cancel()
        mailboxObservation = nil
    }

    // MARK: - Observation

    private func openWindow() {
        rowObservation?.cancel()
        let range = 0..<windowSize
        guard let observation = currentSource()?(range) else {
            rowObservation = nil
            assign(rows: [])
            return
        }
        rowObservation = Task { [weak self] in
            do {
                for try await fresh in observation {
                    guard let self else { return }
                    assign(rows: fresh)
                    hasMore = fresh.count >= range.upperBound
                }
            } catch {
                Self.logger.error("row observation stopped: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func currentSource() -> MessageRowSource? {
        if filter != nil { return filteredSource }
        guard let mailboxId else { return nil }
        let store = store
        let view = listView
        return { range in store.observeMessages(mailboxId: mailboxId, view: view, range: range) }
    }

    /// Keeps `rows` and `sections` in step, so a view can never read one without the other.
    private func assign(rows fresh: [MessageRow]) {
        rows = fresh
        sections = MessageListSection.sections(for: fresh)
    }

    /// The mirror state, live.
    ///
    /// `MailStore` has `observeMailboxes(accountId:)` and no `observeMailbox(id:)`, so the
    /// account's mailboxes are observed and this one is picked out of them
    /// ([ADR-0042](../../../docs/decisions/0042-the-list-watches-one-mailbox-through-its-account.md)),
    /// which also names the replacement: `MailStore.observeMailbox(id:)`.
    private func observeMailbox(id: Int64) async {
        guard let record = try? await store.mailbox(id: id) else { return }
        mailbox = record
        do {
            for try await mailboxes in store.observeMailboxes(accountId: record.accountId) {
                mailbox = mailboxes.first { $0.id == id }
            }
        } catch {
            Self.logger.error("mailbox observation stopped: \(String(describing: error), privacy: .public)")
        }
    }
}
