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
    // WS-31: triage v2
    case snooze
    case chevronForward
    case more
    // WS-30: message view v2
    case replyAll
    case forward
    case encrypted
    case signatureInvalid
    case aiContent
    case translate
    case download
    case print
    case saveToFiles
    case preview
    case unsubscribe
    case readReceipt
    case expand
    // WS-33: Files picker
    case filesBack
    case file
    case imageFile
    case reload
    case shareLink
    // WS-29: message list v2
    case important
    case openInWindow
    case back
    case layout
    // WS-28: sidebar v2
    case priorityInbox
    case unifiedInbox
    case outbox
    case sharedFolder
    case warning
    case newMessage
    case info
    case cloudFile
    case forwardedMessage
    // WS-38 app settings
    case domain
    case group
    case shared
    case edit
    case remove
    case add
    case certificate
    // WS-35 contacts
    case contacts
    case allContacts
    case recentlyContacted
    case favoriteOff
    case upload
    case fullSize
    case socialAvatar
    // WS-34 calendar
    case calendar
    case task
    case flight
    case train
    // WS-37 teams, org chart
    case team
    case orgChart
    case leaveTeam

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
        // MDI `alarm-snooze` — not in the catalogue.
        case .snooze: NCSymbol(asset: "alarm-snooze", systemFallback: "clock.badge")
        case .chevronForward: NCSymbol(asset: "chevron-right", systemFallback: "chevron.right")
        case .more: NCSymbol(asset: "dots-horizontal", systemFallback: "ellipsis.circle")
        case .replyAll: NCSymbol(asset: "reply-all", systemFallback: "arrowshape.turn.up.left.2")
        case .forward: NCSymbol(asset: "share", systemFallback: "arrowshape.turn.up.right")
        case .encrypted: .lockOutline
        case .signatureInvalid: NCSymbol(asset: "lock-off-outline", systemFallback: "lock.slash")
        case .aiContent: NCSymbol(asset: "creation", systemFallback: "sparkles")
        case .translate: NCSymbol(asset: "translate", systemFallback: "character.bubble")
        case .download: .downloadOutline
        case .print: NCSymbol(asset: "printer", systemFallback: "printer")
        case .saveToFiles: .folderUpload
        case .preview: NCSymbol(asset: "eye-outline", systemFallback: "eye")
        case .unsubscribe: NCSymbol(asset: "email-remove-outline", systemFallback: "envelope.badge.minus")
        case .readReceipt: NCSymbol(asset: "email-check-outline", systemFallback: "envelope.badge")
        case .expand: .chevronDown
        case .filesBack: .arrowLeft
        case .file: NCSymbol(asset: "file-outline", systemFallback: "doc")
        case .imageFile: NCSymbol(asset: "file-image-outline", systemFallback: "photo")
        case .reload: NCSymbol(asset: "refresh", systemFallback: "arrow.clockwise")
        case .shareLink: .linkVariant
        case .important: NCSymbol(asset: "label-variant", systemFallback: "exclamationmark.circle")
        case .openInWindow: NCSymbol(asset: "open-in-new", systemFallback: "macwindow.badge.plus")
        case .back: NCSymbol(asset: "chevron-left", systemFallback: "chevron.left")
        case .layout: NCSymbol(asset: "view-split-vertical", systemFallback: "rectangle.split.3x1")
        case .priorityInbox: NCSymbol(asset: "label-variant-outline", systemFallback: "bolt.horizontal")
        case .unifiedInbox: NCSymbol(asset: "inbox-multiple", systemFallback: "tray.2")
        case .outbox: NCSymbol(asset: "inbox-arrow-up", systemFallback: "tray.and.arrow.up")
        case .sharedFolder: NCSymbol(asset: "folder-account-outline", systemFallback: "folder.badge.person.crop")
        case .warning: NCSymbol(asset: "alert-outline", systemFallback: "exclamationmark.triangle")
        case .newMessage: .pencil
        case .info: NCSymbol(asset: "information-outline", systemFallback: "info.circle")
        case .cloudFile: NCSymbol(asset: "cloud-outline", systemFallback: "icloud")
        case .forwardedMessage: NCSymbol(asset: "email-outline", systemFallback: "envelope")
        case .domain: NCSymbol(asset: "domain", systemFallback: "globe")
        case .group: .accountGroup
        case .shared: .shareVariantOutline
        case .edit: .pencilOutline
        case .remove: .close
        case .add: .plus
        case .certificate: NCSymbol(asset: "certificate-outline", systemFallback: "checkmark.seal")
        case .contacts: .contacts
        case .allContacts: .accountMultipleOutline
        case .recentlyContacted: .clockOutline
        case .favoriteOff: .starOutline
        case .upload: .upload
        case .fullSize: .fullscreen
        case .socialAvatar: NCSymbol(asset: "cloud-download-outline", systemFallback: "icloud.and.arrow.down")
        case .calendar: .calendarAccountOutline
        case .task: NCSymbol(asset: "checkbox-marked-circle-outline", systemFallback: "checklist")
        case .flight: NCSymbol(asset: "airplane", systemFallback: "airplane")
        case .train: NCSymbol(asset: "train", systemFallback: "tram")
        case .team: .accountMultiple
        case .orgChart: NCSymbol(asset: "sitemap-outline", systemFallback: "point.3.connected.trianglepath.dotted")
        case .leaveTeam: NCSymbol(asset: "logout", systemFallback: "rectangle.portrait.and.arrow.right")
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
        case .snooze: .text("Snooze")
        case .chevronForward: .text("Open")
        case .more: .text("More actions")
        case .replyAll: .text("Reply all")
        case .forward: .text("Forward")
        case .encrypted: .text("Encrypted")
        case .signatureInvalid: .text("Signature unverified")
        case .aiContent: .text("Contains AI content")
        case .translate: .text("Translate")
        case .download: .text("Download")
        case .print: .text("Print")
        case .saveToFiles: .text("Save to Files")
        case .preview: .text("Preview")
        case .unsubscribe: .text("Unsubscribe")
        case .readReceipt: .text("Read receipt")
        case .expand: .text("Expand")
        case .filesBack: .text("Back")
        case .file: .text("File")
        case .imageFile: .text("Image")
        case .reload: .text("Reload")
        case .shareLink: .text("Share link")
        case .important: .text("Important")
        case .openInWindow: .text("Open in New Window")
        case .back: .text("Back")
        case .layout: .text("View options")
        case .priorityInbox: .text("Priority inbox")
        case .unifiedInbox: .text("All inboxes")
        case .outbox: .text("Outbox")
        case .sharedFolder: .text("Shared folder")
        case .warning: .text("Warning")
        case .newMessage: .text("New message")
        case .info: .text("Information")
        case .cloudFile: .text("From Files")
        case .forwardedMessage: .text("Forwarded message")
        case .domain: .text("Domain")
        case .group: .text("Group")
        case .shared: .text("Shared")
        case .edit: .text("Edit")
        case .remove: .text("Remove")
        case .add: .text("Add")
        case .certificate: .text("Certificate")
        case .contacts: .text("Address book")
        case .allContacts: .text("All contacts")
        case .recentlyContacted: .text("Recently contacted")
        case .favoriteOff: .text("Not a favorite")
        case .upload: .text("Upload")
        case .fullSize: .text("Full size")
        case .socialAvatar: .text("Picture from social network")
        case .calendar: .text("Calendar")
        case .task: .text("Task")
        case .flight: .text("Flight")
        case .train: .text("Train")
        case .team: .text("Team")
        case .orgChart: .text("Organization chart")
        case .leaveTeam: .text("Leave team")
        }
    }

    /// Renders directly, for a glyph that is not sitting inside another component's `icon:`
    /// slot: the message list's leading accessory column, a toolbar button, the sidebar
    /// footer's sync glyph.
    func view(size: NCIcon.Size = .medium, label: NCAccessibilityLabel? = nil) -> some View {
        NCIcon(symbol, label: label ?? defaultLabel, size: size)
    }
}
