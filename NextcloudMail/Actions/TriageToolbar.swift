// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The message pane's toolbar: Archive, Delete, Junk, Move ▾, Star, Mark unread, Refresh
/// ([ux-spec.md](../../docs/product/ux-spec.md#message-view)).
///
/// No button here binds a key. Every shortcut is registered once, in `MailCommands`, so that
/// it appears in the menu bar with its glyph; a second binding on the toolbar button would
/// give the same key two owners and one of them would never fire. The key still *reads* here,
/// in the tooltip, from the same `NCKeyboardShortcut` the menu item binds.
struct TriageToolbar: ToolbarContent {
    let context: TriageContext

    var body: some ToolbarContent {
        ToolbarItemGroup {
            button(.archive)
            button(.delete)
            button(.junk)
            MoveToMenu(context: context)
            button(.star)
            button(.unread)
            TriageMoreMenu(context: context)
            button(.refresh)
        }
    }

    private func button(_ action: TriageAction) -> some View {
        TriageButton(context: context, action: action)
    }
}

/// One toolbar glyph.
///
/// The reason an action cannot run goes into `.help` and into `accessibilityHint`. A disabled
/// AppKit control does not track the pointer, so the tooltip on a greyed-out button never
/// appears — which is why the same sentence is the *title* of the disabled item in
/// ``TriageContextMenu``, where it does render
/// ([ADR-0050](../../docs/decisions/0050-an-unavailable-action-says-why-in-the-menu.md)).
struct TriageButton: View {
    let context: TriageContext
    let action: TriageAction

    var body: some View {
        let availability = context.availability(of: action)
        let isRunning = action == .refresh && context.isRefreshing?() == true
        Button {
            Task { await context.perform(action) }
        } label: {
            if isRunning {
                // The sync passes are still going. A spinner in the glyph's place, so a click
                // visibly did something and a second click is not offered.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Refreshing"))
            } else {
                (action.symbol ?? .folder).view(label: .text(action.label))
            }
        }
        .buttonStyle(.icon)
        .help(isRunning ? "Refreshing…" : action.help(reason: availability.reason))
        .accessibilityLabel(Text(action.label))
        .triageReason(availability.reason)
        .disabled(isRunning || !context.isEnabled(action))
    }
}

/// Move ▾.
///
/// A popover with a filter field rather than the `Menu` the specification asks for. A
/// `TextField` is not something an `NSMenu` can hold, and SwiftUI renders a macOS `Menu` into
/// one, so "a menu over the mailbox tree with a filter field" cannot be both halves at once
/// ([ADR-0052](../../docs/decisions/0052-move-is-a-popover-because-a-menu-cannot-hold-a-field.md)).
/// The popover holds §4.7's picker — search, breadcrumbs, the keyboard — in full.
struct MoveToMenu: View {
    let context: TriageContext

    @State private var isPresented = false

    var body: some View {
        let availability = context.availability(of: .move)
        Button {
            isPresented = true
        } label: {
            MailSymbol.folder.view(label: .text(TriageAction.move.label))
        }
        .buttonStyle(.icon)
        .help(TriageAction.move.help(reason: availability.reason))
        .accessibilityLabel(Text(TriageAction.move.label))
        .triageReason(availability.reason)
        .disabled(!context.isEnabled(.move))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MailboxPicker(context: context, selection: context.selection) { isPresented = false }
        }
    }
}

extension View {
    /// Adds the reason an action cannot run as an accessibility hint, and nothing at all when
    /// it can. An empty hint is a hint, and a screen reader announcing one on every working
    /// button is noise.
    @ViewBuilder
    fileprivate func triageReason(_ reason: String?) -> some View {
        if let reason {
            accessibilityHint(Text(reason))
        } else {
            self
        }
    }
}
