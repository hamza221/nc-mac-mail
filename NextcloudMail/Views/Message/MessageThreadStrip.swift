// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The rest of the conversation, under the message: one line each, oldest first, the open
/// one marked.
///
/// Clicking a sibling opens it here rather than navigating, so the detail column never
/// pushes and the back button never appears. Only one message is expanded at a time, which
/// is also what keeps the WebView count at one — see the height note in
/// [rendering.md](../../../docs/architecture/rendering.md).
struct MessageThreadStrip: View {
    let messages: [MessageRow]
    let selectedId: Int64
    let select: (Int64) -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        if messages.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text("\(messages.count) messages in this conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, theme.metrics.spacing.loose)
                    .padding(.top, theme.metrics.spacing.standard)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            row(for: message)
                        }
                    }
                }
            }
        }
    }

    private func row(for message: MessageRow) -> some View {
        Button {
            select(message.id)
        } label: {
            NCListItem(
                message.senderName ?? message.senderEmail ?? "Unknown sender",
                subtitle: message.subject,
                leading: {
                    // `NCListItem` has no initialiser with `details:` and no `leading:`, by
                    // design. The avatar belongs here anyway; noted in the feedback file
                    // because the thread strip is the screen that asked the question.
                    NCAvatar(
                        displayName: message.senderName ?? message.senderEmail ?? "?",
                        user: message.senderEmail,
                        size: .small,
                        label: .decorative
                    )
                },
                details: {
                    NCListItemDetails(date: Date(timeIntervalSince1970: TimeInterval(message.sentAt)))
                }
            )
            .fontWeight(message.isSeen ? .regular : .semibold)
            // The same inset as the caption above and the header, inside the highlight so the
            // selected row's tint still runs edge to edge.
            .padding(.horizontal, theme.metrics.spacing.loose)
            .contentShape(Rectangle())
            .background(message.id == selectedId ? AnyShapeStyle(theme.colors.primarySurface) : AnyShapeStyle(.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                message.id == selectedId
                    ? "Open message from \(message.senderName ?? "unknown sender")"
                    : "Show message from \(message.senderName ?? "unknown sender")"
            )
        )
    }
}
