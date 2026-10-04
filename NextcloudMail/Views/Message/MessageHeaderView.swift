// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NextcloudUI
import SwiftUI

/// The expanded message's header: sender, recipients, date, the badges that apply, and the
/// action bar. Native, and the part of the message that is always available: the envelope is
/// always mirrored, so this draws before the body exists and stays put when the body arrives.
///
/// Addresses are WS-26's `RecipientBubble`, which opens the contact card (§5.11).
struct MessageHeaderView<Menu: View>: View {
    let header: MessageHeader
    let security: MessageSecurityInfo
    /// False in a conversation of one, which has nothing to collapse into.
    let canCollapse: Bool
    let collapse: () -> Void
    /// Nil is the primary reply: Reply all, Reply or Follow up, as the message calls for.
    let reply: (ReplyMode?) -> Void
    let forward: () -> Void
    @ViewBuilder let menu: () -> Menu

    @Environment(\.ncTheme) private var theme
    @State private var showsAllRecipients = false

    /// Past three, the rest collapse behind a count. A mailing list with ninety recipients
    /// is otherwise the whole window.
    private static var collapsedRecipientCount: Int { 3 }

    private var recipients: [(kind: String, address: Address)] {
        header.to.map { ("to", $0) } + header.cc.map { ("cc", $0) } + header.bcc.map { ("bcc", $0) }
    }

    private var visibleRecipients: [(kind: String, address: Address)] {
        showsAllRecipients ? recipients : Array(recipients.prefix(Self.collapsedRecipientCount))
    }

    private var hiddenRecipientCount: Int {
        max(0, recipients.count - visibleRecipients.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            HStack(alignment: .center, spacing: theme.metrics.spacing.standard) {
                if let sender = header.sender {
                    RecipientBubble(email: sender.email ?? "", label: sender.label, accountId: header.accountId)
                        .accessibilityLabel(Text("From \(sender.displayName)"))
                }
                if header.isImportant {
                    MailSymbol.important.view(size: .small, label: .text("Important"))
                        .foregroundStyle(theme.colors.warning.element)
                }
                if header.isFlagged {
                    MailSymbol.star.view(size: .small, label: .text("Starred"))
                        .foregroundStyle(theme.colors.favorite)
                }
                badges
                Spacer(minLength: theme.metrics.spacing.standard)
                Text(header.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(header.sentAt.formatted(date: .complete, time: .standard))
                    .accessibilityLabel(Text("Received \(header.sentAt.formatted(date: .complete, time: .shortened))"))
                actionBar
            }
            .contentShape(Rectangle())
            .onTapGesture { if canCollapse { collapse() } }
            .accessibilityAction(named: Text("Collapse message")) { if canCollapse { collapse() } }

            if !recipients.isEmpty {
                recipientRow
            }
        }
    }

    /// Only what applies: a chip on every message teaches people to ignore chips.
    @ViewBuilder
    private var badges: some View {
        if security.hasAIContent {
            NCChip(String(localized: "Contains AI content"), role: .primary) {
                MailSymbol.aiContent.view(size: .small, label: .decorative)
            }
        }
        if let smime = security.smime {
            NCChip(smime.label, role: smime == .unverified ? .error : .success) {
                (smime == .unverified ? MailSymbol.signatureInvalid : MailSymbol.encrypted)
                    .view(size: .small, label: .decorative)
            }
            .help(smime.label)
        }
    }

    private var actionBar: some View {
        HStack(spacing: theme.metrics.spacing.tight) {
            Button {
                reply(nil)
            } label: {
                (header.hasSeveralRecipients ? MailSymbol.replyAll : MailSymbol.answered)
                    .view(size: .small, label: .text(header.hasSeveralRecipients ? "Reply all" : "Reply"))
            }
            .buttonStyle(.icon)
            .help(header.hasSeveralRecipients ? "Reply all" : "Reply")
            Button(action: forward) {
                MailSymbol.forward.view(size: .small, label: .text("Forward"))
            }
            .buttonStyle(.icon)
            .help("Forward")
            menu()
        }
    }

    private var recipientRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.tight) {
            Text("to")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(visibleRecipients.enumerated()), id: \.offset) { _, entry in
                RecipientBubble(
                    email: entry.address.email ?? "", label: entry.address.label, accountId: header.accountId
                )
                .help(entry.kind == "to" ? "" : entry.kind.uppercased())
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
