// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// What the key composer window answers to, handed to the menu bar through
/// `FocusedValues`.
///
/// The composer (WS-27) sets it with
/// `.focusedSceneValue(\.composerCommands, ComposerCommandActions(...))` on its window root,
/// and binds none of these keys itself: the binding is the menu item's, here, so it is
/// listed and discoverable (ADR-0049). With no composer key, the value is nil and the items
/// are disabled.
struct ComposerCommandActions {
    var send: @MainActor () -> Void
    var saveDraft: @MainActor () -> Void
    /// False while there is no recipient or a send is already running.
    var canSend: Bool
    /// Heading 1–3 in the rich editor; nil in plain text, which has no headings.
    var heading: (@MainActor (Int) -> Void)?
}

extension FocusedValues {
    @Entry var composerCommands: ComposerCommandActions?
}

/// The non-triage keys of §2.6 and the brief: new message, send, save draft, headings.
enum ComposerCommand: String, CaseIterable, Identifiable, Sendable {
    case newMessage
    case send
    case sendNow
    case saveDraft
    case heading1
    case heading2
    case heading3

    var id: String { "composer.\(rawValue)" }

    var title: String {
        switch self {
        case .newMessage: String(localized: "New Message")
        case .send: String(localized: "Send")
        // A second item because one menu item holds one key: ⌘⇧D is the Mac's, ⌘↩ the web's.
        case .sendNow: String(localized: "Send Now")
        case .saveDraft: String(localized: "Save Draft")
        case .heading1: String(localized: "Heading 1")
        case .heading2: String(localized: "Heading 2")
        case .heading3: String(localized: "Heading 3")
        }
    }

    var shortcut: NCKeyboardShortcut {
        switch self {
        case .newMessage: NCKeyboardShortcut("n")
        case .send: NCKeyboardShortcut("d", modifiers: [.command, .shift])
        case .sendNow: NCKeyboardShortcut(.return)
        case .saveDraft: NCKeyboardShortcut("s")
        case .heading1: NCKeyboardShortcut("1", modifiers: [.control, .option])
        case .heading2: NCKeyboardShortcut("2", modifiers: [.control, .option])
        case .heading3: NCKeyboardShortcut("3", modifiers: [.control, .option])
        }
    }

    var headingLevel: Int? {
        switch self {
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: nil
        }
    }
}

/// File ▸ Send / Send Now / Save Draft and Format ▸ Heading 1–3, live only while a composer
/// window is key. A `View` so that it can read `@FocusedValue`.
struct ComposerMenuItems: View {
    let commands: [ComposerCommand]
    @FocusedValue(\.composerCommands) private var composer

    var body: some View {
        ForEach(commands) { command in
            Button(command.title) { run(command) }
                .keyboardShortcut(command.shortcut.keyEquivalent, modifiers: command.shortcut.modifiers)
                .disabled(!isEnabled(command))
        }
    }

    private func isEnabled(_ command: ComposerCommand) -> Bool {
        guard let composer else { return false }
        switch command {
        case .send, .sendNow: return composer.canSend
        case .saveDraft: return true
        case .heading1, .heading2, .heading3: return composer.heading != nil
        case .newMessage: return false
        }
    }

    private func run(_ command: ComposerCommand) {
        guard let composer else { return }
        switch command {
        case .send, .sendNow: composer.send()
        case .saveDraft: composer.saveDraft()
        case .heading1, .heading2, .heading3:
            if let level = command.headingLevel { composer.heading?(level) }
        case .newMessage: break
        }
    }
}

/// File ▸ New Message (⌘N), from any window, through `openComposer` — a view, for the
/// environment. Starts from the open mailbox's account, as `C` does.
struct NewMessageMenuItem: View {
    let context: TriageContext
    @Environment(\.openComposer) private var openComposer

    var body: some View {
        Button(ComposerCommand.newMessage.title) {
            if context.openComposer == nil {
                let open = openComposer
                context.openComposer = { open($0) }
            }
            Task { await context.perform(.compose) }
        }
        .keyboardShortcut(
            ComposerCommand.newMessage.shortcut.keyEquivalent, modifiers: ComposerCommand.newMessage.shortcut.modifiers)
    }
}
