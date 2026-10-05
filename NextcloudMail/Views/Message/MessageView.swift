// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import QuickLook
import SwiftUI

/// The detail column: the conversation, one message drawn in full, and nothing that lets a
/// message phone home.
///
/// The shape follows [ux-spec.md](../../../docs/product/ux-spec.md#message-view-v2-ws-30):
/// collapsed envelopes around one expanded message
/// ([ADR-0085](../../../docs/decisions/0085-thread-mode-expands-one-message-at-a-time.md)).
/// The header is always available, because the envelope is always mirrored, so there is no
/// state in which this view is empty while a message is selected.
struct MessageView: View {
    /// Nil is "nothing selected", which is a state with its own screen rather than a blank
    /// pane.
    let messageId: Int64?
    /// Offline is a fact about the app, not about this message: the same missing body reads
    /// differently with and without a network.
    let isOffline: Bool
    /// Where `⌘P` finds what this pane is showing. Nil in previews and tests, which print
    /// nothing.
    let printer: MessagePrintController?

    @State private var model: MessageViewModel
    @State private var sheet: MessageSheet?
    @State private var unsubscribeOffer: UnsubscribeOffer?
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.openComposer) private var openComposer

    init(
        services: MessageViewServices,
        messageId: Int64?,
        isOffline: Bool = false,
        printer: MessagePrintController? = nil
    ) {
        self.messageId = messageId
        self.isOffline = isOffline
        self.printer = printer
        _model = State(initialValue: MessageViewModel(services: services))
    }

    var body: some View {
        Group {
            if messageId == nil {
                ContentUnavailableView {
                    Label {
                        Text("No message selected")
                    } icon: {
                        MailSymbol.inbox.view(size: .large, label: .decorative)
                    }
                }
            } else {
                conversation
            }
        }
        .task(id: messageId) { model.present(messageId: messageId) }
        .onChange(of: model.printable, initial: true) { _, printable in
            printer?.show(
                printable,
                services: model.services,
                thread: { [model] in await model.printableThread() },
                from: model
            )
        }
        .onDisappear {
            model.present(messageId: nil)
            printer?.withdraw(from: model)
        }
        .quickLookPreview($model.previewURL)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .source: MessageSourceSheet(model: model)
            case .translation: TranslationSheet(model: model)
            case .saveToFiles(let attachmentIds):
                if let accountId = model.header?.accountId {
                    FilesPicker(accountId: accountId, mode: .folder) { choice in
                        guard case .folder(let path) = choice else { return }
                        Task { await model.saveToFiles(attachmentIds: attachmentIds, targetPath: path) }
                    }
                }
            }
        }
        .confirmationDialog(
            unsubscribeTitle,
            isPresented: Binding(get: { unsubscribeOffer != nil }, set: { if !$0 { unsubscribeOffer = nil } }),
            presenting: unsubscribeOffer
        ) { offer in
            Button("Unsubscribe", role: .destructive) { unsubscribe(offer) }
            Button("Cancel", role: .cancel) { unsubscribeOffer = nil }
        } message: { _ in
            Text(
                "Unsubscribing will stop all messages from the mailing list \(model.header?.sender?.displayName ?? "")")
        }
        .alert(
            "This link does not go where it says",
            isPresented: Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.pendingLink = nil } }),
            presenting: model.pendingLink
        ) { activation in
            Button("Open Anyway") {
                openURL(activation.url)
                model.pendingLink = nil
            }
            Button("Don't Open", role: .cancel) { model.pendingLink = nil }
        } message: { activation in
            if case .confirm(let shown, let target) = activation.verdict {
                Text("It reads \"\(shown)\" and opens \(target).")
            }
        }
    }

    // MARK: - The conversation

    /// The rows before the expanded message, the expanded message, the rows after it.
    ///
    /// The bands of collapsed rows scroll inside a cap so the expanded body keeps the
    /// column's height — a fixed-frame web view cannot grow to its content
    /// ([rendering.md](../../../docs/architecture/rendering.md#the-document-shell)).
    private var conversation: some View {
        let split = ThreadSplit(thread: model.thread, expandedId: model.expandedId)
        return VStack(alignment: .leading, spacing: 0) {
            ThreadSummaryCard(state: model.threadSummary)
            Text(threadSubject)
                .font(.title2.weight(theme.typography.heading))
                .lineLimit(2)
                .help(threadSubject)
                .textSelection(.enabled)
                .padding(.horizontal, theme.metrics.spacing.loose)
                .padding(.vertical, theme.metrics.spacing.standard)
            envelopes(split.before)
            if model.expandedId != nil {
                expandedMessage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            envelopes(split.after)
        }
    }

    private var threadSubject: String {
        let subject = model.thread.first?.subject ?? model.header?.subject
        guard let subject, !subject.isEmpty else { return String(localized: "No subject") }
        return subject
    }

    @ViewBuilder
    private func envelopes(_ rows: [MessageRow]) -> some View {
        if !rows.isEmpty {
            Divider()
            if rows.count <= EnvelopeBand.unscrolledRows {
                envelopeList(rows)
            } else {
                ScrollView { envelopeList(rows) }
                    .frame(maxHeight: EnvelopeBand.maximumHeight)
            }
        }
    }

    private func envelopeList(_ rows: [MessageRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                ThreadEnvelopeRow(
                    row: row,
                    threadSubject: model.thread.first?.subject,
                    toggle: { model.toggle(row.id) }
                )
                Divider()
            }
        }
    }

    private var expandedMessage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            if let header = model.header {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
                    MessageHeaderView(
                        header: header,
                        security: model.security,
                        canCollapse: model.thread.count > 1,
                        collapse: { model.toggle(header.messageId) },
                        reply: reply,
                        forward: { openComposer(.forward(messageIds: [header.messageId], asAttachment: false)) }
                    ) {
                        MessageActionsMenu(
                            model: model,
                            sheet: $sheet,
                            unsubscribe: { unsubscribeOffer = $0 },
                            printMessage: {
                                guard let printable = model.printable else { return }
                                printer?.printOnly(printable, services: model.services)
                            }
                        )
                    }
                    MessageBanners(
                        model: model,
                        unsubscribe: { unsubscribeOffer = $0 },
                        translate: { sheet = .translation }
                    )
                    MessageCalendarCards(model: model)
                }
                .padding(theme.metrics.spacing.loose)
                Divider()
            }

            bodyPane(for: model.presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            let files = model.attachments.filter { !$0.isInline }
            if !files.isEmpty {
                Divider()
                MessageAttachmentsView(
                    attachments: files,
                    preview: { attachment in Task { await model.preview(attachment) } },
                    download: { attachment in
                        saveFile(.attachment(id: attachment.attachmentId), named: attachment.fileName)
                    },
                    saveToFiles: { ids in sheet = .saveToFiles(ids) },
                    downloadZip: { saveFile(.attachmentsZip, named: zipName) }
                )
            }

            if model.header != nil, model.presentation != .encrypted {
                Divider()
                MessageReplyArea(model: model, reply: reply)
            }

            if let failure = model.actionError {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(theme.colors.error.element)
                    .padding(.horizontal, theme.metrics.spacing.loose)
                    .padding(.bottom, theme.metrics.spacing.standard)
            } else if let notice = model.actionNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, theme.metrics.spacing.loose)
                    .padding(.bottom, theme.metrics.spacing.standard)
            }
        }
    }

    @ViewBuilder
    private func bodyPane(for presentation: MessageBodyPresentation) -> some View {
        switch presentation {
        case .waiting:
            ContentUnavailableView {
                Label {
                    Text(isOffline ? "Not downloaded yet" : "Downloading this message")
                } icon: {
                    MailSymbol.sync.view(size: .large, label: .decorative)
                }
            } description: {
                Text(
                    isOffline
                        ? "This message has not been downloaded yet. It will be available when you are back online."
                        : "The rest of this message is on its way."
                )
            }
        case .failed:
            ContentUnavailableView {
                Label {
                    Text("This message could not be downloaded")
                } icon: {
                    MailSymbol.sync.view(size: .large, label: .decorative)
                }
            } actions: {
                Button("Retry") { model.retry() }
                    .buttonStyle(.secondary)
                    .accessibilityLabel(Text("Download this message again"))
            }
        case .blocked(let reason):
            NCNoteCard(.error, title: "This message cannot be displayed") {
                Text("The protections this app renders mail behind could not be installed.")
                Text(reason).font(.caption)
            }
            .padding(theme.metrics.spacing.loose)
        case .encrypted:
            // The notice is the banner above; the body area stays empty on purpose (ADR-0064).
            Color.clear
        case .plain(let text, let signature):
            PlainTextBodyView(text: text, signature: signature, onLink: open(_:))
        case .html(let rendered, let assetContext):
            MessageBodyWebView(
                rendered: rendered,
                assetContext: assetContext,
                store: model.services.store,
                client: model.services.client,
                server: model.services.server,
                onLinkActivated: handle(_:),
                onBlocked: model.contentRuleListFailed(_:)
            )
        }
    }

    // MARK: - Actions

    /// Reply all when there is more than one person to answer, "Follow up" on a follow-up.
    private func reply(_ mode: ReplyMode?) {
        guard let header = model.header else { return }
        let resolved = mode ?? (model.isFollowUp ? .followUp : header.hasSeveralRecipients ? .all : .sender)
        openComposer(.reply(messageId: header.messageId, mode: resolved))
    }

    private var unsubscribeTitle: String {
        switch unsubscribeOffer {
        case .mailto?: String(localized: "Unsubscribe via email")
        default: String(localized: "Unsubscribe via link")
        }
    }

    private func unsubscribe(_ offer: UnsubscribeOffer) {
        unsubscribeOffer = nil
        switch offer {
        case .oneClick: Task { await model.unsubscribeOneClick() }
        case .link(let url): openURL(url)
        case .mailto(let url): openComposer(.new(accountId: model.header?.accountId, mailto: url))
        }
    }

    private var zipName: String {
        let subject = model.header?.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "attachments"
        return "\(subject).zip"
    }

    /// The save panel is what grants access outside the container, so there is no file
    /// access here that the reader did not just choose; the exporter writes the bytes.
    private func saveFile(_ what: MessageExport, named name: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageViewModel.sanitisedFileName(name ?? "attachment")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(what, to: url) }
    }

    // MARK: - Links

    private func open(_ url: URL) {
        guard MailLinkScheme.isOpenable(url) else { return }
        handle(
            MessageLinkActivation(url: url, verdict: LinkDisagreement.verdict(text: url.absoluteString, target: url)))
    }

    private func handle(_ activation: MessageLinkActivation) {
        switch activation.verdict {
        case .open:
            openURL(activation.url)
        case .confirm:
            model.pendingLink = activation
        }
    }
}

/// The sheets the pane presents, one at a time.
enum MessageSheet: Identifiable, Hashable {
    case source
    case translation
    /// The attachment ids to save; `[nil]` is the whole message.
    case saveToFiles([String?])

    var id: Self { self }
}

/// The thread split around the expanded message. With nothing expanded every row is
/// "before", so a collapsed conversation reads top to bottom.
struct ThreadSplit: Equatable {
    var before: [MessageRow]
    var after: [MessageRow]

    init(thread: [MessageRow], expandedId: Int64?) {
        guard let expandedId, let index = thread.firstIndex(where: { $0.id == expandedId }) else {
            before = thread.filter { $0.id != expandedId }
            after = []
            return
        }
        before = Array(thread[..<index])
        after = Array(thread[thread.index(after: index)...])
    }
}

/// How much of the pane a band of collapsed envelopes may take, and how many rows show
/// before it scrolls. A window-shape constant, the same kind as `RootSplitView`'s
/// `ColumnWidth`: `NCTheme` has no slot for "how tall is a secondary list".
private enum EnvelopeBand {
    static let maximumHeight = 180.0
    static let unscrolledRows = 3
}
