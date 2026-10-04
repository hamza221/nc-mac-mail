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

        // ⌘N replaces File ▸ New Window: a second main window is not something this app
        // offers, and ⌘N is New Message in every Mac mail client.
        CommandGroup(replacing: .newItem) {
            NewMessageMenuItem(context: context)
        }

        // ⌘S is Save Draft rather than the document Save the template offers; Send sits
        // beside it. All four are live only while a composer window is key.
        CommandGroup(replacing: .saveItem) {
            ComposerMenuItems(commands: [.saveDraft])
            Divider()
            ComposerMenuItems(commands: [.send, .sendNow])
        }

        CommandGroup(replacing: .printItem) {
            item(.printMessage)
        }

        CommandGroup(replacing: .help) {
            KeyboardShortcutsHelpButton()
        }

        CommandMenu(String(localized: "Message")) {
            item(.compose)
            Divider()
            item(.archive)
            item(.junk, title: context.junkTitle)
            item(.delete)
            item(.move)
            Divider()
            item(.star)
            item(.unread)
            item(.important)
            Divider()
            TriageMoreItems(context: context)
            Divider()
            item(.markAllRead)
            item(.refresh)
            Divider()
            item(.previousMessage)
            item(.nextMessage)
        }

        CommandMenu(String(localized: "Format")) {
            ComposerMenuItems(commands: [.heading1, .heading2, .heading3])
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

    private func item(_ action: TriageAction, title: String? = nil) -> some View {
        Button(title ?? action.title) {
            Task { await context.perform(action) }
        }
        .triageShortcut(action)
        .disabled(!context.isEnabled(action))
    }
}
