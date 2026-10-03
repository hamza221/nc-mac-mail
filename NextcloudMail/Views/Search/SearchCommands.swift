// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// ⌘F and ⌘⇧F, in the menu bar.
///
/// In `Commands` and not in a `.keyboardShortcut` on a hidden button, because
/// [ux-spec.md](../../../docs/product/ux-spec.md#keyboard) says so and the reason is sound: a
/// shortcut that exists only as a modifier is undiscoverable, and the menu is where people
/// look for one they have forgotten.
///
/// Both items act on ``SearchModel`` rather than on the field, which is what lets a command
/// built outside the window move a caret inside it.
struct SearchCommands: Commands {
    let model: SearchModel

    var body: some Commands {
        // `.textEditing` is where Find lives in a macOS menu bar, so ⌘F appears under Edit
        // next to the rest of the finding, rather than in a menu of our own invention.
        CommandGroup(after: .textEditing) {
            Button("Search Mail") { model.requestFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel(Text("Search mail in this mailbox"))
            Button("Search All Mail") { model.searchAllMail() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .accessibilityLabel(Text("Search mail in every mailbox and account"))
        }
    }
}
