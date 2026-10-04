// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The attachment row (§5.10): one chip per file, Quick Look on click, Download and Save to
/// Files in each chip's menu, and Save all to Files / Download zip for more than one.
///
/// The view holds no bytes and makes no request: preview and download go through the view
/// model to the mirror or `MessageExporter`, Save to Files through the queue.
struct MessageAttachmentsView: View {
    let attachments: [AttachmentRecord]
    let preview: (AttachmentRecord) -> Void
    let download: (AttachmentRecord) -> Void
    /// Attachment ids to save to Files, after the picker.
    let saveToFiles: ([String?]) -> Void
    let downloadZip: () -> Void

    @Environment(\.ncTheme) private var theme
    @State private var showsAll = false

    /// Past this many, the rest collapse behind "View n more attachments".
    private static var collapsedCount: Int { 6 }

    private var visible: [AttachmentRecord] {
        showsAll ? attachments : Array(attachments.prefix(Self.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            ScrollView(.horizontal) {
                HStack(spacing: theme.metrics.spacing.standard) {
                    ForEach(visible, id: \.attachmentId) { attachment in
                        chip(for: attachment)
                    }
                    overflow
                }
                .padding(.horizontal, theme.metrics.spacing.loose)
                .padding(.vertical, theme.metrics.spacing.standard)
            }
            if attachments.count > 1 {
                HStack(spacing: theme.metrics.spacing.standard) {
                    Button {
                        saveToFiles(attachments.map(\.attachmentId))
                    } label: {
                        Label {
                            Text("Save all to Files")
                        } icon: {
                            MailSymbol.saveToFiles.view(size: .small, label: .decorative)
                        }
                    }
                    Button(action: downloadZip) {
                        Label {
                            Text("Download Zip")
                        } icon: {
                            MailSymbol.download.view(size: .small, label: .decorative)
                        }
                    }
                }
                .buttonStyle(.tertiary)
                .padding(.horizontal, theme.metrics.spacing.loose)
                .padding(.bottom, theme.metrics.spacing.standard)
            }
        }
    }

    @ViewBuilder
    private var overflow: some View {
        let hidden = attachments.count - Self.collapsedCount
        if hidden > 0 {
            Button(showsAll ? "View fewer attachments" : "View \(hidden) more attachments") { showsAll.toggle() }
                .buttonStyle(.tertiary)
        }
    }

    private func chip(for attachment: AttachmentRecord) -> some View {
        Button {
            preview(attachment)
        } label: {
            NCChip(label(for: attachment)) {
                MailSymbol.attachment.view(size: .small, label: .decorative)
            }
        }
        .buttonStyle(.plain)
        .help(Self.name(of: attachment))
        .accessibilityLabel(Text("Preview \(Self.name(of: attachment))"))
        .contextMenu {
            Button("Preview") { preview(attachment) }
            Button("Download") { download(attachment) }
            Button("Save to Files") { saveToFiles([attachment.attachmentId]) }
        }
    }

    /// An attached message has no file name of its own; the web calls it "Embedded message".
    static func name(of attachment: AttachmentRecord) -> String {
        if let name = attachment.fileName, !name.isEmpty { return name }
        if attachment.mime?.lowercased() == "message/rfc822" { return String(localized: "Embedded message") }
        return String(localized: "Attachment")
    }

    private func label(for attachment: AttachmentRecord) -> String {
        let name = Self.name(of: attachment)
        guard let size = attachment.size else { return name }
        return "\(name) \(size.formatted(.byteCount(style: .file)))"
    }
}
