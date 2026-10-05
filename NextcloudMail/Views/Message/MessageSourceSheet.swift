// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudUI
import SwiftUI

/// "Message source" (§5.4): the raw message, monospaced and selectable, from its
/// `messageSource` row. Cached like every server result (ADR-0067), so a source looked at
/// once is there offline.
///
/// Shown as text, never rendered: the source is raw MIME, the one form of a message the
/// rest of this app never puts on screen (ADR-0009).
struct MessageSourceSheet: View {
    let model: MessageViewModel

    @Environment(\.ncTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            HStack {
                Text("Message source").font(.title3.weight(theme.typography.heading))
                Spacer()
                if let source = model.source.value {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(source, forType: .string)
                    }
                    .buttonStyle(.secondary)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: SourceSheetSize.width, minHeight: SourceSheetSize.height)
        .task { model.requestSource() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.source {
        case .idle, .pending:
            ProgressView("Loading the message source…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let source):
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: source)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .empty, .failed:
            ContentUnavailableView {
                Label {
                    Text("The message source could not be loaded")
                } icon: {
                    MailSymbol.sourceCode.view(size: .large, label: .decorative)
                }
            } description: {
                Text("It is fetched once and kept. Try again when you are online.")
            }
        }
    }
}

/// The source sheet's opening size: a window shape, not a theme token.
private enum SourceSheetSize {
    static let width = 640.0
    static let height = 480.0
}
