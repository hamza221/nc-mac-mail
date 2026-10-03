// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NextcloudUI
import SwiftUI

/// One row of the message list.
///
/// The shape is [ux-spec.md](../../../docs/product/ux-spec.md#message-list)'s: avatar flush
/// left, sender and subject, then one trailing cluster with the date on top and, beneath it on
/// one line, the state glyphs that apply, the thread's size and its unread count.
///
/// Unread is `threadUnreadCount > 0` rather than `!isSeen`
/// ([ADR-0041](../../../docs/decisions/0041-unread-is-the-threads-unread-count.md)), and that
/// is one rule for both views rather than two: `MessageRow`'s thread counts are 1 and 0/1 in
/// the flat view and the real numbers in the threaded one, so a thread with an unread reply
/// reads as unread in threaded and its own unread messages read as unread in flat.
struct MessageListRow: View {
    let row: MessageRow
    /// The sender's picture, read from the mirror. Nil when the row has no address to look
    /// one up by; `NCAvatar` draws coloured initials for that and for a loader that throws.
    var avatar: (@Sendable () async throws -> Image)?

    @Environment(\.ncTheme) private var theme

    private var isUnread: Bool { row.threadUnreadCount > 0 }
    private var senderName: String { row.senderName ?? row.senderEmail ?? String(localized: "Unknown sender") }
    private var subject: String { row.subject ?? String(localized: "No subject") }
    private var sentAt: Date { Date(timeIntervalSince1970: TimeInterval(row.sentAt)) }

    var body: some View {
        NCListItem(senderName, subtitle: subject) {
            NCAvatar(
                displayName: senderName,
                user: row.senderEmail,
                size: .medium,
                label: .decorative,
                load: avatar
            )
        } details: {
            // One cluster, not the library's details plus a separate trailing slot. Those
            // put the unread bubble under the date and the thread-size bubble in its own
            // column, vertically centred, so the two counts never lined up. The date-only
            // `NCListItemDetails` keeps the library's date formatting and voice label. The
            // second line holds every count, so they share a baseline.
            VStack(alignment: .trailing, spacing: theme.metrics.spacing.hairline) {
                NCListItemDetails(date: sentAt, unreadCount: 0)
                HStack(spacing: theme.metrics.spacing.hairline) {
                    accessories
                    // Quiet, not brand-filled: the unread bubble beside it is the one that
                    // is meant to be seen, and two filled bubbles on one row compete.
                    NCCounterBubble(
                        count: row.threadCount > 1 ? row.threadCount : 0, role: .neutral, label: .decorative)
                    NCCounterBubble(count: row.threadUnreadCount, role: .highlighted, label: .decorative)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .fontWeight(isUnread ? .semibold : nil)
        // `NCListItem` combines its children, so one label replaces the lot. The order is the
        // one the UX specification asks VoiceOver to read.
        .accessibilityLabel(Text(spokenDescription))
    }

    /// Only the glyphs that apply, on the trailing side.
    ///
    /// They used to be three fixed-width slots ahead of the avatar, so that rows lined up, and
    /// on the many rows with no state that was a column of blank space pushing every avatar
    /// and subject right. On the trailing side, the date and count are already right-aligned
    /// and the avatar column stays fixed whatever is drawn here.
    @ViewBuilder
    private var accessories: some View {
        if row.isFlagged { glyph(.star, tint: theme.colors.favorite) }
        if row.hasAttachments { glyph(.attachment, tint: nil) }
        if row.isAnswered { glyph(.answered, tint: nil) }
    }

    /// `.decorative`, and not to silence the compiler: `NCListItem` combines its children
    /// into one element and ``spokenDescription`` already says "starred", "has an
    /// attachment" and "replied to" in words. A label here would be unreachable, and adding
    /// one would leave two places that have to agree about what a glyph means.
    private func glyph(_ symbol: MailSymbol, tint: NCDynamicColor?) -> some View {
        symbol.view(size: .small, label: .decorative)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }

    /// "Unread, from Sookie St. James, The Dragonfly opening menu, 3 minutes ago."
    ///
    /// Everything the row conveys with weight, colour or a glyph is said here in words, which
    /// is what "nothing is conveyed by colour alone" means for a row that combines into one
    /// accessibility element.
    private var spokenDescription: String {
        var parts: [String] = []
        if isUnread { parts.append(String(localized: "Unread")) }
        parts.append(String(localized: "from \(senderName)"))
        parts.append(subject)
        if row.threadCount > 1 { parts.append(String(localized: "\(row.threadCount) messages")) }
        if row.isFlagged { parts.append(String(localized: "starred")) }
        if row.hasAttachments { parts.append(String(localized: "has an attachment")) }
        if row.isAnswered { parts.append(String(localized: "replied to")) }
        parts.append(sentAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }
}
