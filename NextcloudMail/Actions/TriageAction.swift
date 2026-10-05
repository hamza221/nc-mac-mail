// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// Every keystroke the app answers to, in one table.
///
/// The toolbar, the context menu, the menu bar and the shortcut list all read this, so the
/// key printed in a tooltip cannot drift from the key that is bound. `NCKeyboardShortcut`
/// carries both halves — it renders as `⌘P` and it hands `.keyboardShortcut` a
/// `KeyEquivalent` — which is why the shortcut is stored as one value rather than as a
/// character beside a piece of display text.
///
/// The table is [ux-spec.md](../../docs/product/ux-spec.md#keyboard)'s, and two rows of it
/// are deliberately absent. `↑` and `↓` are not here because `List(selection:)` already moves
/// the selection with them; a menu item would take the arrow keys away from the list, the
/// search field and the message body
/// ([ADR-0049](../../docs/decisions/0049-the-arrow-keys-stay-with-the-list.md)). `⌘F` and
/// `⌘⇧F` are here but are only offered to the menu bar when a search handler is wired, for
/// the same reason in reverse: `.searchable` binds `⌘F` itself, and two bindings mean one
/// dead one.
enum TriageAction: String, CaseIterable, Identifiable, Sendable {
    case archive
    case delete
    case junk
    case move
    case star
    case unread
    case important
    case markAllRead
    case refresh
    case printMessage
    case previousMessage
    case nextMessage
    case search
    case searchAllMail
    // v2 (WS-31)
    case compose
    case editTags
    case snooze
    case unsnooze
    case quickAction
    case forwardAsAttachment
    case editAsNew

    var id: String { rawValue }

    /// The menu item's title. A toggle names the state it is about rather than the state it
    /// would produce, because the produced state depends on the selection and a title that
    /// changes under the pointer is harder to hit than one that does not.
    var label: LocalizedStringResource {
        switch self {
        case .archive: "Archive"
        case .delete: "Delete"
        case .junk: "Mark as Junk"
        case .move: "Move to Folder"
        case .star: "Star"
        case .unread: "Mark as Unread"
        case .important: "Mark as Important"
        case .markAllRead: "Mark All as Read"
        case .refresh: "Refresh"
        case .printMessage: "Print Message\u{2026}"
        case .previousMessage: "Previous Message"
        case .nextMessage: "Next Message"
        case .search: "Find"
        case .searchAllMail: "Find in All Mail"
        case .compose: "New Message"
        case .editTags: "Edit Tags\u{2026}"
        case .snooze: "Snooze Until\u{2026}"
        case .unsnooze: "Unsnooze"
        case .quickAction: "Quick Action"
        case .forwardAsAttachment: "Forward as Attachment"
        case .editAsNew: "Edit as New Message"
        }
    }

    /// The same text, resolved, for the places that take a `String`: a tooltip, an
    /// `UndoManager` action name.
    var title: String { String(localized: label) }

    /// The glyph, for the actions that appear in the message toolbar
    /// ([ux-spec.md](../../docs/product/ux-spec.md#message-view)). Nil for the ones that live
    /// only in a menu, which read as text and need no icon.
    var symbol: MailSymbol? {
        switch self {
        case .archive: .archive
        case .delete: .trash
        case .junk: .junk
        case .move: .folder
        case .editTags: .tag
        case .snooze: .snooze
        case .star: .star
        case .unread: .unread
        case .refresh: .sync
        default: nil
        }
    }

    var shortcut: NCKeyboardShortcut? {
        switch self {
        case .archive: NCKeyboardShortcut("a", modifiers: [])
        case .star: NCKeyboardShortcut("s", modifiers: [])
        case .unread: NCKeyboardShortcut("u", modifiers: [])
        case .junk: NCKeyboardShortcut("j", modifiers: [])
        case .delete: NCKeyboardShortcut(.delete, modifiers: [])
        case .refresh: NCKeyboardShortcut("r", modifiers: [])
        case .previousMessage: NCKeyboardShortcut(.leftArrow, modifiers: [])
        case .nextMessage: NCKeyboardShortcut(.rightArrow, modifiers: [])
        case .printMessage: NCKeyboardShortcut("p")
        case .search: NCKeyboardShortcut("f")
        case .searchAllMail: NCKeyboardShortcut("f", modifiers: [.command, .shift])
        // §2.6 lists `C`; the web never bound it. ⌘N is File ▸ New Message (`ComposerCommand`).
        case .compose: NCKeyboardShortcut("c", modifiers: [])
        case .move, .important, .markAllRead, .editTags, .snooze, .unsnooze, .quickAction, .forwardAsAttachment,
            .editAsNew:
            nil
        }
    }

    /// Whether performing this action takes the message out of the list it was in, which is
    /// what decides whether the selection advances afterwards. Starring a message leaves it
    /// where it is, and moving the selection off it would hide the star the user just set.
    var removesFromList: Bool {
        switch self {
        case .archive, .delete, .junk, .move, .snooze, .unsnooze: true
        default: false
        }
    }

    /// The name `⌘Z` shows: "Undo Archive".
    var undoName: String { title }
}

extension View {
    /// Binds an action's shortcut, when it has one.
    ///
    /// One place, so a button in the toolbar and an item in the menu bar cannot end up bound
    /// to different keys.
    @ViewBuilder
    func triageShortcut(_ action: TriageAction) -> some View {
        if let shortcut = action.shortcut {
            keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}

extension TriageAction {
    /// The tooltip: the action, then its key, then — when it cannot run — why not.
    ///
    /// A disabled AppKit control does not track the pointer, so a tooltip on a greyed-out
    /// toolbar button never appears. That is why the reason is repeated as the title of the
    /// disabled context-menu item, which does render, and why this string is also fed to
    /// `accessibilityHint`.
    func help(reason: String?) -> String {
        let name = title
        let keyed = shortcut.map { "\(name) (\(NCKeyboardShortcutGlyphs.string(for: $0)))" } ?? name
        guard let reason else { return keyed }
        return "\(keyed) — \(reason)"
    }
}
