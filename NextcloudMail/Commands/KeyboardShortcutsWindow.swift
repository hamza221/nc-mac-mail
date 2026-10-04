// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// One line of the shortcut list.
struct KeyboardShortcutRow: Identifiable, Equatable, Sendable {
    let id: String
    /// The glyphs, as a key cap prints them: `⌘⇧F`.
    let keys: String
    let action: String
    /// How the key is spoken, because `⌘⇧F` reads as approximately nothing.
    let spoken: String

    init(id: String, keys: String, action: String, spoken: String? = nil) {
        self.id = id
        self.keys = keys
        self.action = action
        self.spoken = spoken ?? keys
    }

    init(_ action: TriageAction, shortcut: NCKeyboardShortcut) {
        self.init(
            id: action.rawValue,
            keys: NCKeyboardShortcutGlyphs.string(for: shortcut),
            action: action.title,
            spoken: NCKeyboardShortcutGlyphs.accessibilityDescription(for: shortcut)
        )
    }

    /// Everything the window lists: every action this app binds, then the keys the platform
    /// binds for it.
    ///
    /// The second group is not decoration. `↑`, `↓`, `⇧`-click and `Space` are in
    /// [ux-spec.md](../../docs/product/ux-spec.md#keyboard)'s table and they work, but they
    /// are `List`'s and the WebView's rather than ours, so they have no menu item to be
    /// discovered from and this is the only place they are written down
    /// ([ADR-0049](../../docs/decisions/0049-the-arrow-keys-stay-with-the-list.md)).
    static var all: [KeyboardShortcutRow] {
        let bound = TriageAction.allCases.compactMap { action in
            action.shortcut.map { KeyboardShortcutRow(action, shortcut: $0) }
        }
        let composer = ComposerCommand.allCases.map { command in
            KeyboardShortcutRow(
                id: command.id,
                keys: NCKeyboardShortcutGlyphs.string(for: command.shortcut),
                action: command.title,
                spoken: NCKeyboardShortcutGlyphs.accessibilityDescription(for: command.shortcut)
            )
        }
        return bound + composer + platform
    }

    static let platform: [KeyboardShortcutRow] = [
        KeyboardShortcutRow(
            id: "list.up",
            keys: "\u{2191}  \u{2193}",
            action: String(localized: "Move the selection in the list"),
            spoken: String(localized: "Up arrow, down arrow")
        ),
        KeyboardShortcutRow(
            id: "list.extend",
            keys: "\u{21E7}",
            action: String(localized: "Extend the selection when clicking"),
            spoken: String(localized: "Shift")
        ),
        KeyboardShortcutRow(
            id: "body.scroll",
            keys: "\u{2423}",
            action: String(localized: "Scroll the message body"),
            spoken: String(localized: "Space")
        ),
        KeyboardShortcutRow(
            id: "undo",
            keys: "\u{2318}Z",
            action: String(localized: "Undo the last action"),
            spoken: String(localized: "Command Z")
        ),
    ]
}

/// The window behind Help ▸ Keyboard Shortcuts.
///
/// Add it to the `App`'s scene body beside `WindowGroup`. It is a `Window` rather than a
/// `WindowGroup` because a second copy of a reference card is never what anyone wanted.
struct KeyboardShortcutsWindow: Scene {
    static let id = "keyboard-shortcuts"

    var body: some Scene {
        Window(String(localized: "Keyboard Shortcuts"), id: Self.id) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
    }
}

struct KeyboardShortcutsView: View {
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            ForEach(KeyboardShortcutRow.all) { row in
                HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.standard) {
                    Text(row.keys)
                        .font(.body.monospaced())
                        .frame(width: Self.keyColumnWidth, alignment: .leading)
                        .accessibilityLabel(Text(row.spoken))
                    Text(row.action)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: Self.width, alignment: .leading)
    }

    private static let keyColumnWidth = 72.0
    private static let width = 360.0
}

/// Help ▸ Keyboard Shortcuts. A `View` rather than a bare `Button` in `MailCommands` so that
/// it can read `openWindow` from the environment, which a `Commands` body cannot.
struct KeyboardShortcutsHelpButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Keyboard Shortcuts")) {
            openWindow(id: KeyboardShortcutsWindow.id)
        }
    }
}
