// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// What a row shows beyond the envelope: read from the mirror by ``MessageListStore`` for the
/// whole window at once, so a row never queries the database itself.
struct MessageRowAdornments: Equatable {
    var tags: [TagRecord] = []
    var attachments: [AttachmentChip] = []
    /// The AI summary when there is one, else the preview text.
    var preview: String?
    var previewIsSummary = false
}

/// One row of the message list.
///
/// The shape is [ux-spec.md](../../../docs/product/ux-spec.md#message-list)'s: avatar flush
/// left, sender and subject, then one trailing cluster with the date on top and, beneath it on
/// one line, the state glyphs that apply, the thread's size and its unread count. Below that,
/// outside compact mode, the WS-29 adornments: the preview or AI summary, then tag and
/// attachment chips.
///
/// Unread is `threadUnreadCount > 0` rather than `!isSeen`
/// ([ADR-0041](../../../docs/decisions/0041-unread-is-the-threads-unread-count.md)), one rule
/// for both views.
struct MessageListRow: View {
    let row: MessageRow
    /// The sender's picture, read from the mirror. Nil when the row has no address to look
    /// one up by; `NCAvatar` draws coloured initials for that and for a loader that throws.
    var avatar: (@Sendable () async throws -> Image)?
    var adornments = MessageRowAdornments()
    /// `compact-mode`: a small avatar and no adornment lines.
    var isCompact = false

    @Environment(\.ncTheme) private var theme

    /// The web shows three attachment chips and then "+N".
    static let attachmentChipLimit = 3

    private var isUnread: Bool { row.threadUnreadCount > 0 }
    private var sender: Address { Address(label: row.senderName, email: row.senderEmail) }
    private var senderName: String {
        sender.displayName.isEmpty ? String(localized: "Unknown sender") : sender.displayName
    }
    /// Name and address, for the tooltip and VoiceOver. The row has room for the name only,
    /// and the name is the sender's to choose, so the address has to be one hover away.
    private var senderNameAndAddress: String {
        sender.displayName.isEmpty ? senderName : sender.nameAndAddress
    }
    private var subject: String { row.subject ?? String(localized: "No subject") }
    /// "Draft: …", as the web client prefixes a draft's subject.
    private var subjectLine: String {
        row.isDraft ? String(localized: "Draft: \(subject)") : subject
    }
    private var sentAt: Date { Date(timeIntervalSince1970: TimeInterval(row.sentAt)) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
            NCListItem(senderName, subtitle: subjectLine) {
                NCAvatar(
                    displayName: senderName,
                    user: row.senderEmail,
                    size: isCompact ? .small : .medium,
                    label: .decorative,
                    load: avatar
                )
            } details: {
                // One cluster, not the library's details plus a separate trailing slot, so the
                // counts share a baseline under the date.
                VStack(alignment: .trailing, spacing: theme.metrics.spacing.hairline) {
                    NCListItemDetails(date: sentAt, unreadCount: 0)
                    HStack(spacing: theme.metrics.spacing.hairline) {
                        accessories
                        NCCounterBubble(
                            count: row.threadCount > 1 ? row.threadCount : 0, role: .neutral, label: .decorative)
                        NCCounterBubble(count: row.threadUnreadCount, role: .highlighted, label: .decorative)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if !isCompact { adornmentLines }
        }
        .fontWeight(isUnread ? .semibold : nil)
        // The adornments sit outside `NCListItem`, so the row combines them itself; one label
        // replaces the lot, in the order the specification asks VoiceOver to read.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spokenDescription))
        .help(Text(verbatim: senderNameAndAddress))
    }

    /// `NCListItem` has no third line, so the adornments are a second block indented to the
    /// text column: the avatar's width plus the item's own spacing (library-feedback, WS-29).
    @ViewBuilder
    private var adornmentLines: some View {
        let chips = adornments.attachments.prefix(Self.attachmentChipLimit)
        let remaining = adornments.attachments.count - chips.count
        if adornments.preview != nil || !adornments.tags.isEmpty || !chips.isEmpty {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                if let preview = adornments.preview {
                    HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.tight) {
                        if adornments.previewIsSummary {
                            MailSymbol.aiContent.view(size: .small, label: .decorative)
                                .foregroundStyle(.secondary)
                                .help(Text("This summary was AI-generated"))
                        }
                        Text(verbatim: preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .fontWeight(nil)
                }
                if !adornments.tags.isEmpty || !chips.isEmpty {
                    // Chips scroll off the trailing edge rather than wrap: a row's height is
                    // what keeps a long list scannable.
                    HStack(spacing: theme.metrics.spacing.tight) {
                        ForEach(adornments.tags, id: \.id) { tag in
                            NCChip(tag.displayName, tint: Self.tint(tag.color))
                        }
                        ForEach(Array(chips), id: \.attachmentId) { attachment in
                            NCChip(attachment.fileName) {
                                MailSymbol.attachment.view(size: .small, label: .decorative)
                            }
                        }
                        if remaining > 0 {
                            NCChip(String(localized: "+\(remaining)"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                }
            }
            .fontWeight(nil)
            .padding(.leading, avatarDiameter + theme.metrics.spacing.standard)
        }
    }

    private var avatarDiameter: CGFloat {
        isCompact ? theme.metrics.avatar.small : theme.metrics.avatar.medium
    }

    /// A tag's own colour: data that carries its colour is what `NCChip(tint:)` is for.
    static func tint(_ hex: String?) -> NCDynamicColor? {
        guard let hex, let rgb = NCRGB(hex: hex) else { return nil }
        return NCDynamicColor(light: rgb, dark: rgb)
    }

    /// Only the glyphs that apply, on the trailing side.
    @ViewBuilder
    private var accessories: some View {
        if row.isImportant { glyph(.important, tint: theme.colors.warning.element) }
        if row.isFlagged { glyph(.star, tint: theme.colors.favorite) }
        if row.hasAttachments { glyph(.attachment, tint: nil) }
        if row.isAnswered { glyph(.answered, tint: nil) }
    }

    /// `.decorative`: the row combines into one element and ``spokenDescription`` already
    /// says each state in words.
    private func glyph(_ symbol: MailSymbol, tint: NCDynamicColor?) -> some View {
        symbol.view(size: .small, label: .decorative)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }

    /// "Unread, from Sookie St. James <sookie@dragonfly.example>, The Dragonfly opening menu,
    /// 3 minutes ago."
    private var spokenDescription: String {
        var parts: [String] = []
        if isUnread { parts.append(String(localized: "Unread")) }
        if row.isDraft { parts.append(String(localized: "Draft")) }
        parts.append(String(localized: "from \(senderNameAndAddress)"))
        parts.append(subject)
        if row.threadCount > 1 { parts.append(String(localized: "\(row.threadCount) messages")) }
        if row.isImportant { parts.append(String(localized: "important")) }
        if row.isFlagged { parts.append(String(localized: "starred")) }
        if row.hasAttachments { parts.append(String(localized: "has an attachment")) }
        if row.isAnswered { parts.append(String(localized: "replied to")) }
        if !adornments.tags.isEmpty {
            parts.append(String(localized: "tagged \(adornments.tags.map(\.displayName).joined(separator: ", "))"))
        }
        if !isCompact, let preview = adornments.preview {
            parts.append(adornments.previewIsSummary ? String(localized: "AI summary: \(preview)") : preview)
        }
        parts.append(sentAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }
}
