// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// Every shortcut, in the menu bar, with its key beside it.
///
/// This is the only place a triage key is bound. A shortcut that lives in a
/// `.keyboardShortcut` modifier on a button is undiscoverable — nothing lists it, and the
/// only way to learn it is to be told — so the toolbar buttons carry the key in their
/// tooltips and the binding lives here
/// ([ux-spec.md](../../docs/product/ux-spec.md#keyboard)).
///
/// Attach it in the `App`'s scene body:
///
/// ```swift
/// WindowGroup { RootSplitView() … }
///     .commands { MailCommands(context: session.triage) }
/// ```
struct MailCommands: Commands {
    let context: TriageContext

    var body: some Commands {
        // Replacing rather than adding: the standard Edit ▸ Undo drives
        // `@Environment(\.undoManager)`, which a plain `WindowGroup` leaves nil, so the
        // system item would be permanently grey while `MessageActions` held a perfectly good
        // stack (ADR-0051).
        CommandGroup(replacing: .undoRedo) {
            Button(String(localized: "Undo")) { context.actions.undo() }
                .keyboardShortcut("z")
                .disabled(!context.actions.canUndo)
            Button(String(localized: "Redo")) { context.actions.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!context.actions.canRedo)
        }

        CommandGroup(replacing: .printItem) {
            item(.printMessage)
        }

        CommandGroup(replacing: .help) {
            KeyboardShortcutsHelpButton()
        }

        CommandMenu(String(localized: "Message")) {
            item(.archive)
            item(.junk)
            item(.delete)
            Divider()
            item(.star)
            item(.unread)
            item(.important)
            Divider()
            item(.markAllRead)
            item(.refresh)
            Divider()
            item(.previousMessage)
            item(.nextMessage)
        }

        // Only when something can answer them. `.searchable` binds `⌘F` itself, so offering a
        // second binding here while WS-11's field is on screen would leave one of the two
        // dead and no way to tell which.
        if context.search != nil {
            CommandGroup(after: .textEditing) {
                item(.search)
                item(.searchAllMail)
            }
        }
    }

    private func item(_ action: TriageAction) -> some View {
        Button(String(localized: action.label)) {
            Task { await context.perform(action) }
        }
        .triageShortcut(action)
        .disabled(!context.isEnabled(action))
    }
}
