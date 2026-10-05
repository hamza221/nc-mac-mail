// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The §4.4 "…" and §4.5 header "…" actions, as one list of menu items.
///
/// The menu bar's Message menu, the list's context menu and the toolbar's More ▾ all show
/// this, so the three cannot drift. Each item goes through ``TriageContext/perform(_:)`` or
/// one of its siblings — the single entry point v1 established.
struct TriageMoreItems: View {
    let context: TriageContext

    var body: some View {
        item(.editTags)
        if context.actions.selectionIsSnoozed {
            item(.unsnooze)
        } else {
            SnoozeMenu(context: context)
        }
        QuickActionsMenu(context: context)
        Divider()
        item(.forwardAsAttachment)
        item(.editAsNew)
    }

    private func item(_ action: TriageAction) -> some View {
        TriageMenuItem(context: context, action: action)
    }
}

/// One menu item for an action. No key binding: keys live in `MailCommands` only, and none
/// of the actions this list shows has one.
struct TriageMenuItem: View {
    let context: TriageContext
    let action: TriageAction
    var title: String?

    var body: some View {
        let availability = context.availability(of: action)
        Button(title ?? action.title) {
            Task { await context.perform(action) }
        }
        .disabled(!context.isEnabled(action))
        .help(action.help(reason: availability.reason))
    }
}

/// Snooze ▸ with §4.4's presets for the moment the menu is drawn, then Custom….
///
/// A preset is re-resolved when it is chosen, against the clock *then*: a menu drawn at
/// 16:59 and clicked at 17:01 must not snooze "later today" to a time the rules no longer
/// offer.
struct SnoozeMenu: View {
    let context: TriageContext

    var body: some View {
        Menu(String(localized: "Snooze")) {
            ForEach(SnoozePresets.options(now: .now)) { option in
                Button(option.label()) {
                    guard let current = SnoozePresets.options(now: .now).first(where: { $0.preset == option.preset })
                    else { return }
                    Task { await context.snooze(until: current.date) }
                }
            }
            Divider()
            Button(String(localized: "Custom\u{2026}")) {
                Task { await context.perform(.snooze) }
            }
        }
        .disabled(!context.isEnabled(.snooze))
    }
}

/// Quick Actions ▸: the account's actions the source folders' ACLs allow, then Manage….
struct QuickActionsMenu: View {
    let context: TriageContext
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu(String(localized: "Quick Actions")) {
            if context.quickActions.isEmpty {
                Text("No quick actions")
            }
            ForEach(context.quickActions) { quickAction in
                Button(quickAction.name) {
                    Task { await context.run(quickAction) }
                }
            }
            Divider()
            Button(String(localized: "Manage Quick Actions\u{2026}")) { openSettings() }
        }
        .disabled(!context.isEnabled(.quickAction))
    }
}

/// More ▾ in the message toolbar: the actions the toolbar has no room for.
struct TriageMoreMenu: View {
    let context: TriageContext

    var body: some View {
        Menu {
            TriageMoreItems(context: context)
        } label: {
            MailSymbol.more.view(label: .text("More actions"))
        }
        .menuIndicator(.hidden)
        .help(String(localized: "More actions"))
        .accessibilityLabel(Text("More actions"))
        .disabled(!context.hasSelection)
    }
}
