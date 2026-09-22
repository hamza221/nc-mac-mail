// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// Every icon this app draws, mapped once.
///
/// `NextcloudUI`'s catalogue has 91 Material Design Icons
/// ([ui-components.md](../../docs/reference/ui-components.md#gaps-what-the-library-does-not-give-us))
/// and a mail client's chrome needs a handful it does not have yet. Rather than reach for
/// `Image(systemName:)` at each call site — which is what `.swiftlint.yml`'s
/// `ncm_no_sf_symbol` rule exists to stop — every icon the app uses goes through this type.
/// When the catalogue grows, only the `symbol` case below changes.
enum MailSymbol: CaseIterable {
    case inbox
    case sent
    case drafts
    case archive
    case junk
    case trash
    case folder
    case star
    case attachment
    case unread
    case sync
    case tag
    case answered

    /// The symbol to hand a library component whose icon slot takes one directly, such as
    /// `NCNavigationItem(icon:)`. `NCIcon` already falls back to `systemFallback` for any
    /// asset name absent from `NCSymbol.bundledAssets`, so the four cases with a real MDI
    /// asset reuse the generated catalogue entry, and the rest carry a name that only ever
    /// resolves to its fallback.
    var symbol: NCSymbol {
        switch self {
        // MDI `inbox` — not in the catalogue.
        case .inbox: NCSymbol(asset: "inbox", systemFallback: "tray")
        // MDI `send` — not in the catalogue.
        case .sent: NCSymbol(asset: "send", systemFallback: "paperplane")
        // MDI `file-document-outline` — not in the catalogue.
        case .drafts: NCSymbol(asset: "file-document-outline", systemFallback: "doc.text")
        // MDI `archive-arrow-down-outline` — not in the catalogue.
        case .archive: NCSymbol(asset: "archive-arrow-down-outline", systemFallback: "archivebox")
        case .junk: .alertOctagonOutline
        case .trash: .trashCanOutline
        case .folder: .folderOutline
        case .star: .star
        // MDI `paperclip` — not in the catalogue.
        case .attachment: NCSymbol(asset: "paperclip", systemFallback: "paperclip")
        // MDI `email-open-outline` — not in the catalogue.
        case .unread: NCSymbol(asset: "email-open-outline", systemFallback: "envelope.open")
        // MDI `sync` — not in the catalogue.
        case .sync: NCSymbol(asset: "sync", systemFallback: "arrow.triangle.2.circlepath")
        // MDI `tag-outline` — not in the catalogue.
        case .tag: NCSymbol(asset: "tag-outline", systemFallback: "tag")
        // MDI `reply` — not in the catalogue.
        case .answered: NCSymbol(asset: "reply", systemFallback: "arrowshape.turn.up.left")
        }
    }

    /// A sensible label for a case shown on its own. A caller with more context — "starred",
    /// not "star" — passes its own label to ``view(size:label:)`` instead.
    var defaultLabel: NCAccessibilityLabel {
        switch self {
        case .inbox: .text("Inbox")
        case .sent: .text("Sent")
        case .drafts: .text("Drafts")
        case .archive: .text("Archive")
        case .junk: .text("Junk")
        case .trash: .text("Trash")
        case .folder: .text("Folder")
        case .star: .text("Starred")
        case .attachment: .text("Attachment")
        case .unread: .text("Unread")
        case .sync: .text("Syncing")
        case .tag: .text("Tag")
        case .answered: .text("Replied")
        }
    }

    /// Renders directly, for a glyph that is not sitting inside another component's `icon:`
    /// slot: the message list's leading accessory column, a toolbar button, the sidebar
    /// footer's sync glyph.
    func view(size: NCIcon.Size = .medium, label: NCAccessibilityLabel? = nil) -> some View {
        NCIcon(symbol, label: label ?? defaultLabel, size: size)
    }
}
