// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The right-click menu on a list row, acting on the whole selection
/// ([ux-spec.md](../../docs/product/ux-spec.md#message-list)).
///
/// Attached with `.contextMenu { TriageContextMenu(context: context) }`. It deliberately does
/// not take the row it was opened on: right-clicking inside a selection acts on all of it,
/// which is what the specification says and what every other mail client does.
///
/// An action the account cannot do keeps its place and says why, as its title. That is the
/// one surface where the explanation is readable — a disabled toolbar button cannot show a
/// tooltip ([ADR-0050](../../docs/decisions/0050-an-unavailable-action-says-why-in-the-menu.md)).
struct TriageContextMenu: View {
    let context: TriageContext

    var body: some View {
        item(.archive)
        item(.junk)
        item(.delete)
        Divider()
        item(.star)
        item(.unread)
        item(.important)
        Divider()
        MoveSubmenu(context: context)
    }

    @ViewBuilder
    private func item(_ action: TriageAction) -> some View {
        let availability = context.availability(of: action)
        Button(role: action == .delete ? .destructive : nil) {
            Task { await context.perform(action) }
        } label: {
            availability.reason.map { Text($0) } ?? Text(action.label)
        }
        .disabled(!context.isEnabled(action))
    }
}

/// Move, inside a context menu.
///
/// Flat rather than nested: the destinations come from
/// ``TriageContext/moveDestinations()`` already flattened with their depth, and a context
/// menu has no room for a filter field. The toolbar's ``MoveToMenu`` is the one with the
/// filter.
private struct MoveSubmenu: View {
    let context: TriageContext

    @State private var destinations: [MoveDestination] = []

    var body: some View {
        Menu {
            ForEach(destinations) { destination in
                Button(destination.displayName) {
                    Task { await context.move(to: destination.id) }
                }
            }
        } label: {
            Text(TriageAction.move.label)
        }
        .disabled(!context.isEnabled(.move) || destinations.isEmpty)
        .task { destinations = await context.moveDestinations() }
    }
}
