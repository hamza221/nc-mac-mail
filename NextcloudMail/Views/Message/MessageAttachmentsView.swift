// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI

/// The attachment row: one chip per file, a save panel behind each, and Quick Look for the
/// ones that are pictures.
struct MessageAttachmentsView: View {
    let attachments: [AttachmentRecord]
    /// The bytes, from the mirror when it has them and from the server when it does not.
    let load: (AttachmentRecord) async throws -> Data
    @Binding var previewURL: URL?

    @Environment(\.ncTheme) private var theme
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(theme.colors.error.element)
            }
            ScrollView(.horizontal) {
                HStack(spacing: theme.metrics.spacing.standard) {
                    ForEach(attachments, id: \.attachmentId) { attachment in
                        chip(for: attachment)
                    }
                }
                .padding(.horizontal, theme.metrics.spacing.loose)
                .padding(.vertical, theme.metrics.spacing.standard)
            }
        }
    }

    private func chip(for attachment: AttachmentRecord) -> some View {
        Button {
            Task { await activate(attachment) }
        } label: {
            NCChip(label(for: attachment)) {
                MailSymbol.attachment.view(size: .small, label: .decorative)
            }
        }
        .buttonStyle(.plain)
        .help(attachment.isImage ? "Preview" : "Save…")
        .accessibilityLabel(Text(accessibilityLabel(for: attachment)))
    }

    private func label(for attachment: AttachmentRecord) -> String {
        let name = attachment.fileName ?? "Attachment"
        guard let size = attachment.size else { return name }
        return "\(name) \(size.formatted(.byteCount(style: .file)))"
    }

    private func accessibilityLabel(for attachment: AttachmentRecord) -> String {
        let name = attachment.fileName ?? "Attachment"
        return attachment.isImage ? "Preview \(name)" : "Save \(name)"
    }

    private func activate(_ attachment: AttachmentRecord) async {
        do {
            let data = try await load(attachment)
            if attachment.isImage {
                previewURL = try write(data, named: attachment.fileName ?? "attachment")
            } else {
                try save(data, suggesting: attachment.fileName ?? "attachment")
            }
            failure = nil
        } catch {
            // No dialogue for something a retry fixes (ux-spec.md); the row says so instead.
            failure = "That attachment could not be opened."
            renderLog.error("attachment failed: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// Into the container's temporary directory, which Quick Look can read and nothing
    /// outside the sandbox can.
    private func write(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "attachments",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: sanitised(name), directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The save panel is what grants access outside the container, so there is no file
    /// access here that the reader did not just choose.
    private func save(_ data: Data, suggesting name: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitised(name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    /// A file name from a message is attacker-controlled: `../../Library/…` is a real
    /// attachment name, and the save panel is not the place to find that out.
    private func sanitised(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) { return "attachment" }
        return trimmed
    }
}
