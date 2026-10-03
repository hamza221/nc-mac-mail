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
    case blockedImages
    case settings
    case account
    case storage
    // Editor toolbar (WS-20).
    case bold
    case italic
    case underline
    case strikethrough
    case subscriptText
    case superscriptText
    case insertImage
    case alignLeft
    case alignCenter
    case alignRight
    case alignJustify
    case directionLeftToRight
    case directionRightToLeft
    case bulletedList
    case numberedList
    case blockQuote
    case link
    case clearFormatting
    case findReplace
    case sourceCode
    case undo
    case redo
    case formatting

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
        // MDI `image-off-outline` — not in the catalogue. Asked for by WS-09, whose blocked
        // content bar leans on `NCNoteCard(.warning)`'s alert glyph instead; an alert is what
        // a warning card says about itself, not what was blocked.
        case .blockedImages: NCSymbol(asset: "image-off-outline", systemFallback: "photo.badge.exclamationmark")
        case .settings: .cogOutline
        case .account: .accountOutline
        // MDI `harddisk` — not in the catalogue.
        case .storage: NCSymbol(asset: "harddisk", systemFallback: "internaldrive")
        // MDI `format-bold` and friends — none of the editor glyphs are in the catalogue.
        case .bold: NCSymbol(asset: "format-bold", systemFallback: "bold")
        case .italic: NCSymbol(asset: "format-italic", systemFallback: "italic")
        case .underline: NCSymbol(asset: "format-underline", systemFallback: "underline")
        case .strikethrough: NCSymbol(asset: "format-strikethrough-variant", systemFallback: "strikethrough")
        case .subscriptText: NCSymbol(asset: "format-subscript", systemFallback: "textformat.subscript")
        case .superscriptText: NCSymbol(asset: "format-superscript", systemFallback: "textformat.superscript")
        case .insertImage: NCSymbol(asset: "image-plus", systemFallback: "photo.badge.plus")
        case .alignLeft: NCSymbol(asset: "format-align-left", systemFallback: "text.alignleft")
        case .alignCenter: NCSymbol(asset: "format-align-center", systemFallback: "text.aligncenter")
        case .alignRight: NCSymbol(asset: "format-align-right", systemFallback: "text.alignright")
        case .alignJustify: NCSymbol(asset: "format-align-justify", systemFallback: "text.justify")
        case .directionLeftToRight:
            NCSymbol(asset: "format-pilcrow-arrow-right", systemFallback: "arrow.right.to.line")
        case .directionRightToLeft:
            NCSymbol(asset: "format-pilcrow-arrow-left", systemFallback: "arrow.left.to.line")
        case .bulletedList: NCSymbol(asset: "format-list-bulleted", systemFallback: "list.bullet")
        case .numberedList: NCSymbol(asset: "format-list-numbered", systemFallback: "list.number")
        case .blockQuote: NCSymbol(asset: "format-quote-close", systemFallback: "text.quote")
        case .link: NCSymbol(asset: "link-variant", systemFallback: "link")
        case .clearFormatting: NCSymbol(asset: "format-clear", systemFallback: "eraser")
        case .findReplace: NCSymbol(asset: "find-replace", systemFallback: "magnifyingglass")
        case .sourceCode: NCSymbol(asset: "code-tags", systemFallback: "chevron.left.forwardslash.chevron.right")
        case .undo: NCSymbol(asset: "undo", systemFallback: "arrow.uturn.backward")
        case .redo: NCSymbol(asset: "redo", systemFallback: "arrow.uturn.forward")
        case .formatting: NCSymbol(asset: "format-text", systemFallback: "textformat")
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
        case .blockedImages: .text("Remote content blocked")
        case .settings: .text("Settings")
        case .account: .text("Account")
        case .storage: .text("Storage")
        case .bold: .text("Bold")
        case .italic: .text("Italic")
        case .underline: .text("Underline")
        case .strikethrough: .text("Strikethrough")
        case .subscriptText: .text("Subscript")
        case .superscriptText: .text("Superscript")
        case .insertImage: .text("Insert image")
        case .alignLeft: .text("Align left")
        case .alignCenter: .text("Align centre")
        case .alignRight: .text("Align right")
        case .alignJustify: .text("Justify")
        case .directionLeftToRight: .text("Left to right")
        case .directionRightToLeft: .text("Right to left")
        case .bulletedList: .text("Bulleted list")
        case .numberedList: .text("Numbered list")
        case .blockQuote: .text("Block quote")
        case .link: .text("Link")
        case .clearFormatting: .text("Remove formatting")
        case .findReplace: .text("Find and replace")
        case .sourceCode: .text("Source")
        case .undo: .text("Undo")
        case .redo: .text("Redo")
        case .formatting: .text("Formatting")
        }
    }

    /// Renders directly, for a glyph that is not sitting inside another component's `icon:`
    /// slot: the message list's leading accessory column, a toolbar button, the sidebar
    /// footer's sync glyph.
    func view(size: NCIcon.Size = .medium, label: NCAccessibilityLabel? = nil) -> some View {
        NCIcon(symbol, label: label ?? defaultLabel, size: size)
    }
}
