// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import OSLog
import SwiftUI

/// Every draft somebody asked to send, across accounts, read from the `draft` rows the
/// drafts engine moves along (ADR-0083). The banner is a view of those rows and nothing
/// else: "Sending message…" is a row in `undo`, "Could not send message" a row in `failed`,
/// and "Message sent" a row that was sending and left the table.
@MainActor
@Observable
final class PendingSendsModel {
    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable {
            case sending(requestedAt: Int64)
            case failed(reason: String?)
            case sent
        }

        let draftId: Int64
        let accountId: Int64
        let subject: String
        let kind: Kind

        var id: Int64 { draftId }
    }

    private(set) var notices: [Notice] = []

    @ObservationIgnored private var byAccount: [Int64: [DraftRecord]] = [:]
    /// Rows last seen in a send state; one disappearing from here was sent.
    @ObservationIgnored private var inFlight: [Int64: DraftRecord] = [:]
    @ObservationIgnored private var sentNotices: [Int64: Notice] = [:]
    @ObservationIgnored private var dismissedFailures: Set<Int64> = []
    @ObservationIgnored private var observation: Task<Void, Never>?

    private let store: MailStore
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "composer")

    init(store: MailStore) {
        self.store = store
    }

    func start() {
        guard observation == nil else { return }
        let store = store
        observation = Task { [weak self] in
            do {
                for try await accounts in store.observeAccounts() {
                    await self?.observe(accountIds: accounts.map(\.id))
                }
            } catch {
                Self.logger.error("pending sends: accounts observation stopped")
            }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    @ObservationIgnored private var accountTasks: [Int64: Task<Void, Never>] = [:]

    private func observe(accountIds: [Int64]) async {
        for (id, task) in accountTasks where !accountIds.contains(id) {
            task.cancel()
            accountTasks[id] = nil
            byAccount[id] = nil
        }
        let store = store
        for id in accountIds where accountTasks[id] == nil {
            accountTasks[id] = Task { [weak self] in
                do {
                    for try await drafts in store.observeDrafts(accountId: id) {
                        self?.update(accountId: id, drafts: drafts)
                    }
                } catch {
                    Self.logger.error("pending sends: drafts observation stopped")
                }
            }
        }
        rebuild()
    }

    private func update(accountId: Int64, drafts: [DraftRecord]) {
        byAccount[accountId] = drafts
        rebuild()
    }

    private func rebuild() {
        let all = byAccount.values.flatMap { $0 }
        var current: [Int64: DraftRecord] = [:]
        for draft in all {
            guard let id = draft.id, let state = draft.sendState.flatMap(DraftSendState.init(rawValue:)) else {
                continue
            }
            if state != .closing { current[id] = draft }
        }
        for (id, draft) in inFlight where current[id] == nil && !all.contains(where: { $0.id == id }) {
            let wasSending = draft.sendState != DraftSendState.failed.rawValue
            // A scheduled send leaving the table went to the Outbox, not out of the machine.
            if wasSending && draft.sendAt == nil {
                showSent(Notice(draftId: id, accountId: draft.accountId, subject: draft.subject ?? "", kind: .sent))
            }
        }
        inFlight = current
        for id in dismissedFailures where current[id]?.sendState != DraftSendState.failed.rawValue {
            dismissedFailures.remove(id)
        }

        var next: [Notice] = []
        for draft in current.values.sorted(by: { ($0.sendRequestedAt ?? 0) < ($1.sendRequestedAt ?? 0) }) {
            guard let id = draft.id, let state = draft.sendState.flatMap(DraftSendState.init(rawValue:)) else {
                continue
            }
            let subject = draft.subject ?? ""
            switch state {
            case .undo, .queued, .sending:
                // Scheduled sends get no undo toast (§6.8): the Outbox shows them.
                guard draft.sendAt == nil else { continue }
                next.append(
                    Notice(
                        draftId: id, accountId: draft.accountId, subject: subject,
                        kind: .sending(requestedAt: draft.sendRequestedAt ?? 0)))
            case .failed:
                guard !dismissedFailures.contains(id) else { continue }
                next.append(
                    Notice(
                        draftId: id, accountId: draft.accountId, subject: subject,
                        kind: .failed(reason: draft.syncError)))
            case .closing:
                continue
            }
        }
        notices = next + sentNotices.values.sorted { $0.draftId < $1.draftId }
    }

    private func showSent(_ notice: Notice) {
        sentNotices[notice.draftId] = notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.sentNotices[notice.draftId] = nil
            self?.rebuild()
        }
    }

    func dismiss(_ notice: Notice) {
        switch notice.kind {
        case .sent: sentNotices[notice.draftId] = nil
        case .failed: dismissedFailures.insert(notice.draftId)
        case .sending: return
        }
        rebuild()
    }
}

extension View {
    /// The main window's "Sending message… Undo" strip (§6.9).
    func undoSendBanner(session: AppSession) -> some View {
        modifier(UndoSendBannerModifier(session: session))
    }
}

private struct UndoSendBannerModifier: ViewModifier {
    let session: AppSession
    @State private var model: PendingSendsModel?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let model {
                    UndoSendBanner(model: model, session: session)
                }
            }
            .task {
                let model = ComposerWindows.shared.pendingSends(store: session.store)
                self.model = model
            }
    }
}

/// How a notice enters and leaves the strip. Reduce Motion turns the slide off and leaves
/// the crossfade, which is the substitute the HIG gives for movement (ux-spec.md,
/// Accessibility).
enum UndoSendBannerMotion: Equatable {
    case slide
    case fade

    init(reduceMotion: Bool) {
        self = reduceMotion ? .fade : .slide
    }

    var transition: AnyTransition {
        switch self {
        case .slide: .move(edge: .bottom).combined(with: .opacity)
        case .fade: .opacity
        }
    }
}

struct UndoSendBanner: View {
    let model: PendingSendsModel
    let session: AppSession

    @Environment(\.ncTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = UndoSendBannerMotion(reduceMotion: reduceMotion)
        VStack(spacing: theme.metrics.spacing.tight) {
            ForEach(model.notices) { notice in
                row(notice)
                    .transition(motion.transition)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .animation(.default, value: model.notices)
    }

    @ViewBuilder
    private func row(_ notice: PendingSendsModel.Notice) -> some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            switch notice.kind {
            case .sending:
                ProgressView().controlSize(.small)
                Text("Sending message…")
                Button("Undo") { undo(notice) }
            case .failed(let reason):
                Text("Could not send message")
                    .foregroundStyle(theme.colors.error.element)
                    .help(reason ?? "")
                Button("Edit") { edit(notice) }
                Button("Dismiss") { model.dismiss(notice) }
            case .sent:
                Text("Message sent")
                Button("Dismiss") { model.dismiss(notice) }
            }
        }
        .padding(.horizontal, theme.metrics.spacing.loose)
        .padding(.vertical, theme.metrics.spacing.standard)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: theme.metrics.radius.element))
        .accessibilityElement(children: .combine)
    }

    private func undo(_ notice: PendingSendsModel.Notice) {
        guard let outbox = session.engine.outbox(accountId: notice.accountId) else { return }
        Task {
            let undone = await outbox.undoSend(draftId: notice.draftId)
            guard undone else { return }
            // The composer that sent it is hidden, not closed; it reappears as "Edit
            // message". A draft with no window behind it (a relaunch inside the window)
            // goes to the Drafts folder rather than becoming an invisible local row.
            if !ComposerWindows.shared.reveal(draftId: notice.draftId) {
                await outbox.closeDraft(notice.draftId)
            }
        }
    }

    /// A failed send is a draft again. Its composer comes back; with none behind it, the
    /// draft is filed in Drafts where the list can open it.
    private func edit(_ notice: PendingSendsModel.Notice) {
        guard !ComposerWindows.shared.reveal(draftId: notice.draftId) else { return }
        guard let outbox = session.engine.outbox(accountId: notice.accountId) else { return }
        Task { await outbox.closeDraft(notice.draftId) }
    }
}
