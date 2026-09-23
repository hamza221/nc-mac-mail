// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import QuickLook
import SwiftUI

/// The detail column: native chrome, one body, and nothing that lets a message phone home.
///
/// The shape follows [ux-spec.md](../../../docs/product/ux-spec.md#message-view): the header
/// is always available, because the envelope is always mirrored, so there is no state in
/// which this view is empty while a message is selected.
struct MessageView: View {
    /// Nil is "nothing selected", which is a state with its own screen rather than a blank
    /// pane.
    let messageId: Int64?
    /// Offline is a fact about the app, not about this message: the same missing body reads
    /// differently with and without a network.
    let isOffline: Bool
    let select: (Int64) -> Void

    @State private var model: MessageViewModel
    @Environment(\.ncTheme) private var theme
    @Environment(\.openURL) private var openURL

    init(
        services: MessageViewServices,
        messageId: Int64?,
        isOffline: Bool = false,
        select: @escaping (Int64) -> Void = { _ in }
    ) {
        self.messageId = messageId
        self.isOffline = isOffline
        self.select = select
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
                message
            }
        }
        .task(id: messageId) { model.present(messageId: messageId) }
        .onDisappear { model.present(messageId: nil) }
        .quickLookPreview($model.previewURL)
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

    @ViewBuilder
    private var message: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = model.header {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
                    MessageHeaderView(
                        header: header,
                        avatar: model.services.store.avatarLoader(for: header.sender?.email)
                    )
                    if model.hasBlockedRemoteContent, !model.showsRemoteImages, !model.isSenderTrusted {
                        BlockedContentBar(
                            showImages: model.showImages,
                            alwaysShow: { Task { await model.alwaysShowFromThisSender() } }
                        )
                    }
                }
                .padding(theme.metrics.spacing.loose)
                Divider()
            }

            bodyPane(for: model.presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.attachments.isEmpty {
                Divider()
                MessageAttachmentsView(
                    attachments: model.attachments,
                    load: model.attachmentData,
                    previewURL: $model.previewURL
                )
            }

            if let selected = messageId {
                MessageThreadStrip(messages: model.thread, selectedId: selected, select: select)
                    .frame(maxHeight: ThreadStrip.maximumHeight)
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

/// How much of the pane the rest of the conversation may take. A window-shape constant, the
/// same kind as `RootSplitView`'s `ColumnWidth`: `NCTheme` has no slot for "how tall is a
/// secondary list", and it is not a spacing or a radius.
private enum ThreadStrip {
    static let maximumHeight = 180.0
}
