// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailSync
import NextcloudUI
import SwiftUI

/// The expanded message's ⋯ menu (§5.4): everything that acts on this one message rather
/// than on the list's selection.
struct MessageActionsMenu: View {
    let model: MessageViewModel
    @Binding var sheet: MessageSheet?
    let unsubscribe: (UnsubscribeOffer) -> Void
    /// "Print message": this message only. `⌘P` prints the whole conversation.
    let printMessage: () -> Void

    @Environment(\.openComposer) private var openComposer
    /// "Link copied" for two seconds after a copy, as the web labels it.
    @State private var linkCopied = false

    var body: some View {
        Menu {
            if let header = model.header {
                Button("Reply to sender only") {
                    openComposer(.reply(messageId: header.messageId, mode: .sender))
                }
                Button("Forward as attachment") {
                    openComposer(.forward(messageIds: [header.messageId], asAttachment: true))
                }
                Button("Edit as new message") { openComposer(.editAsNew(messageId: header.messageId)) }
                Divider()
                Button(header.isFlagged ? "Unstar" : "Star") { Task { await model.toggle(flag: .star) } }
                Button(header.isImportant ? "Mark unimportant" : "Mark important") {
                    Task { await model.toggle(flag: .important) }
                }
                Button(header.isSeen ? "Mark unread" : "Mark read") { Task { await model.toggle(flag: .unread) } }
                Divider()
                if model.offersTranslation {
                    Button("Translate") { sheet = .translation }
                }
                Button(linkCopied ? "Link copied" : "Copy direct link") { copyLink() }
                    .disabled(MessageDirectLink.url(messageIdHeader: header.messageIdHeader) == nil)
                    .help("Only for message recipients")
                Button("View source") { sheet = .source }
                Button("Print message", action: printMessage)
                    .disabled(model.printable == nil)
                Button("Download message") { downloadMessage(header) }
                Button("Save message to Files") { sheet = .saveToFiles([nil]) }
                if let domain = model.senderDomain {
                    Divider()
                    Button("Always show images from \(domain)") { Task { await model.trustSenderDomain() } }
                }
                if let offer = model.security.unsubscribe {
                    Button("Unsubscribe") { unsubscribe(offer) }
                }
            }
        } label: {
            MailSymbol.more.view(size: .small, label: .text("More actions"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func copyLink() {
        guard model.copyDirectLink() else { return }
        linkCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            linkCopied = false
        }
    }

    private func downloadMessage(_ header: MessageHeader) {
        let panel = NSSavePanel()
        let subject = header.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "message"
        panel.nameFieldStringValue = MessageViewModel.sanitisedFileName("\(subject).eml")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(.eml, to: url) }
    }
}
