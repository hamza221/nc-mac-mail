// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NextcloudUI
import SwiftUI

/// Subject, sender, recipients and date. Native, and the part of the message that is always
/// available: the envelope is always mirrored, so this draws before the body exists and
/// stays put when the body arrives.
struct MessageHeaderView: View {
    let header: MessageHeader
    /// The sender's picture, read from the mirror. Nil when there is no address to look one
    /// up by; the bubble draws coloured initials for that and for a loader that throws.
    var avatar: (@Sendable () async throws -> Image)?

    @Environment(\.ncTheme) private var theme
    @State private var showsAllRecipients = false

    /// Past three, the rest collapse behind a count. A mailing list with ninety recipients
    /// is otherwise the whole window.
    private static let collapsedRecipientCount = 3

    private var recipients: [Address] { header.to + header.cc }

    private var visibleRecipients: [Address] {
        showsAllRecipients ? recipients : Array(recipients.prefix(Self.collapsedRecipientCount))
    }

    private var hiddenRecipientCount: Int {
        max(0, recipients.count - visibleRecipients.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text(header.subject ?? "No subject")
                .font(.title2.weight(theme.typography.heading))
                .textSelection(.enabled)

            HStack(spacing: theme.metrics.spacing.standard) {
                if let sender = header.sender {
                    NCUserBubble(
                        displayName: sender.displayName,
                        user: sender.email,
                        size: .medium,
                        load: avatar
                    )
                    .accessibilityLabel(Text("From \(sender.displayName)"))
                }
                if header.isFlagged {
                    MailSymbol.star.view(size: .small, label: .text("Starred"))
                        .foregroundStyle(theme.colors.favorite)
                }
                Spacer(minLength: theme.metrics.spacing.standard)
                Text(header.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Received \(header.sentAt.formatted(date: .complete, time: .shortened))"))
            }

            if !recipients.isEmpty {
                recipientRow
            }
        }
    }

    private var recipientRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.tight) {
            Text("to")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(visibleRecipients.enumerated()), id: \.offset) { _, address in
                NCChip(address.displayName)
            }
            if hiddenRecipientCount > 0 {
                Button {
                    showsAllRecipients = true
                } label: {
                    Text("+\(hiddenRecipientCount)")
                }
                .buttonStyle(.tertiary)
                .accessibilityLabel(Text("Show \(hiddenRecipientCount) more recipients"))
            } else if showsAllRecipients, recipients.count > Self.collapsedRecipientCount {
                Button {
                    showsAllRecipients = false
                } label: {
                    Text("Fewer")
                }
                .buttonStyle(.tertiary)
                .accessibilityLabel(Text("Show fewer recipients"))
            }
        }
    }
}
