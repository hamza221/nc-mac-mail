// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import OSLog
import SwiftUI

/// The Outbox list (§4.9) over mirrored `outboxMessage` rows. The rows are WS-21's mirror
/// of `GET /api/outbox`; every action goes through the account's `OutboxSender`, which asks
/// the mirror to re-read afterwards, so the list changes because the rows did.
@MainActor
@Observable
final class OutboxListModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var items: [OutboxItem] = []
    private(set) var phase: Phase = .loading
    /// The one-line outcome of the last action ("Message sent", "Could not delete message").
    var notice: String?

    @ObservationIgnored private var observation: Task<Void, Never>?
    private let session: AppSession
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "outbox")

    init(session: AppSession) {
        self.session = session
    }

    func start() async {
        do {
            for try await rows in session.store.observeOutboxMessages() {
                items = rows.map(OutboxItem.init)
                phase = .loaded
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("outbox observation failed: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }

    func sendNow(_ item: OutboxItem) async {
        await run(item, success: "Message sent", failure: "Could not send message") {
            try await $0.sendNow(outboxId: item.id)
        }
    }

    func copyToSent(_ item: OutboxItem) async {
        await run(
            item, success: "Message copied to \"Sent\" folder", failure: "Could not copy message to \"Sent\" folder"
        ) {
            try await $0.copyToSent(outboxId: item.id)
        }
    }

    func delete(_ item: OutboxItem) async {
        await run(item, success: "Message deleted", failure: "Could not delete message") {
            try await $0.deleteOutbox(outboxId: item.id)
        }
    }

    private func run(
        _ item: OutboxItem,
        success: String,
        failure: String,
        _ action: (OutboxSender) async throws -> Void
    ) async {
        guard let outbox = session.engine.outbox(accountId: item.accountId) else {
            notice = failure
            return
        }
        do {
            try await action(outbox)
            notice = success
        } catch {
            Self.logger.error("outbox action failed: \(String(describing: error), privacy: .public)")
            notice = failure
        }
    }
}

struct OutboxView: View {
    let session: AppSession

    @State private var model: OutboxListModel
    @State private var selection: Int64?
    @Environment(\.openComposer) private var openComposer
    @Environment(\.ncTheme) private var theme

    init(session: AppSession) {
        self.session = session
        _model = State(initialValue: OutboxListModel(session: session))
    }

    var body: some View {
        content
            .task { await model.start() }
            .safeAreaInset(edge: .bottom) {
                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(theme.metrics.spacing.standard)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(4))
                            model.notice = nil
                        }
                }
            }
            .navigationTitle("Outbox")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label {
                    Text("Could not open outbox")
                } icon: {
                    MailSymbol.sent.view(size: .large, label: .decorative)
                }
            }
        case .loaded where model.items.isEmpty:
            ContentUnavailableView {
                Label {
                    Text("No messages in this folder")
                } icon: {
                    MailSymbol.sent.view(size: .large, label: .decorative)
                }
            } description: {
                Text("Pending or not sent messages will show up here")
            }
        case .loaded:
            List(selection: $selection) {
                ForEach(model.items) { item in
                    OutboxRow(item: item)
                        .tag(item.id)
                        .contextMenu { menu(for: item) }
                }
            }
            .contextMenu(forSelectionType: Int64.self) { _ in
            } primaryAction: { ids in
                guard let id = ids.first, let item = model.items.first(where: { $0.id == id }), item.canEdit else {
                    return
                }
                openComposer(.outbox(outboxId: item.id))
            }
        }
    }

    @ViewBuilder
    private func menu(for item: OutboxItem) -> some View {
        if item.canEdit {
            Button("Edit message") { openComposer(.outbox(outboxId: item.id)) }
        }
        if item.canSendNow {
            Button("Send now") { Task { await model.sendNow(item) } }
        }
        if item.canCopyToSent {
            Button("Copy to \"Sent\" Folder") { Task { await model.copyToSent(item) } }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(item) } }
    }
}

private struct OutboxRow: View {
    let item: OutboxItem
    @Environment(\.ncTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.metrics.spacing.standard) {
            NCAvatar(
                displayName: item.recipients.first.map { $0.label ?? $0.email } ?? "?",
                size: .medium,
                label: .decorative
            )
            VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                Text(verbatim: item.recipientLine)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: item.displaySubject)
                    .lineLimit(1)
                detail
                    .font(.caption)
            }
        }
        .padding(.vertical, theme.metrics.spacing.tight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        switch item.status {
        case .sentCopyFailed:
            Text("Could not copy to \"Sent\" folder").foregroundStyle(theme.colors.error.element)
        case .serverError:
            Text("Mail server error").foregroundStyle(theme.colors.error.element)
        case .notSent:
            Text("Message could not be sent").foregroundStyle(theme.colors.error.element)
        case .pending:
            if let sendAt = item.sendAt {
                Text(sendAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
            }
        }
    }
}
