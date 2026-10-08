// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// One collapsed message of the conversation (§5.2): avatar, sender, the preview or
/// "Encrypted message", its own subject when it says something the thread's does not, and
/// the date. Clicking expands it in place; it does not change the list's selection
/// ([ADR-0085](../../../docs/decisions/0085-thread-mode-expands-one-message-at-a-time.md)).
struct ThreadEnvelopeRow: View {
    let row: MessageRow
    let threadSubject: String?
    let toggle: () -> Void

    @Environment(\.ncTheme) private var theme

    private var address: Address { Address(label: row.senderName, email: row.senderEmail) }
    private var sender: String {
        address.displayName.isEmpty ? String(localized: "Unknown sender") : address.displayName
    }
    /// The line has room for the name only, and the name is the sender's to choose, so the
    /// address rides along in the tooltip and the VoiceOver label.
    private var senderNameAndAddress: String {
        address.displayName.isEmpty ? sender : address.nameAndAddress
    }

    private var subtitle: String {
        let preview = row.isEncrypted ? String(localized: "Encrypted message") : (row.previewText ?? "")
        guard ThreadSubject.differs(row.subject, from: threadSubject), let subject = row.subject else { return preview }
        return preview.isEmpty ? subject : "\(subject) — \(preview)"
    }

    private var sentAt: Date { Date(timeIntervalSince1970: TimeInterval(row.sentAt)) }

    var body: some View {
        Button(action: toggle) {
            NCListItem(
                sender,
                subtitle: subtitle,
                leading: {
                    NCAvatar(displayName: sender, user: row.senderEmail, size: .small, label: .decorative)
                },
                details: {
                    NCListItemDetails(date: sentAt)
                }
            )
            .fontWeight(row.isSeen ? .regular : .semibold)
            .padding(.horizontal, theme.metrics.spacing.loose)
            .contentShape(Rectangle())
            .help(Text(verbatim: "\(senderNameAndAddress)\n\(sentAt.formatted(date: .complete, time: .standard))"))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Expand message from \(senderNameAndAddress)"))
    }
}
