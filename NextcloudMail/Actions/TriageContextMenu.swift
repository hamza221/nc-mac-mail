// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The right-click menu on a list row ([ux-spec.md](../../docs/product/ux-spec.md#message-list)).
///
/// Attached with `.contextMenu(forSelectionType: Int64.self) { ids in TriageContextMenu(...) }`.
/// `targetIds` are the rows the click landed on. Right-clicking inside a selection acts on
/// all of it, and right-clicking elsewhere acts on that row, which is what the specification
/// says and what every other mail client does. ``TriageContext/adopt(_:)`` makes that the
/// selection before the action runs, so one code path performs every action.
///
/// An action the account cannot do keeps its place and says why, as its title. That is the
/// one surface where the explanation is readable — a disabled toolbar button cannot show a
/// tooltip ([ADR-0050](../../docs/decisions/0050-an-unavailable-action-says-why-in-the-menu.md)).
struct TriageContextMenu: View {
    let context: TriageContext
    let targetIds: Set<Int64>

    var body: some View {
        item(.archive)
        item(.junk)
        item(.delete)
        Divider()
        item(.star)
        item(.unread)
        item(.important)
        Divider()
        MoveSubmenu(context: context, targetIds: targetIds)
    }

    @ViewBuilder
    private func item(_ action: TriageAction) -> some View {
        let availability = context.availability(of: action)
        Button(role: action == .delete ? .destructive : nil) {
            context.adopt(targetIds)
            Task { await context.perform(action) }
        } label: {
            availability.reason.map { Text($0) } ?? Text(action.label)
        }
        .disabled(targetIds.isEmpty || !availability.isAvailable)
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
    let targetIds: Set<Int64>

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
        .disabled(targetIds.isEmpty || destinations.isEmpty)
        // The destinations depend on the account of the rows clicked, so those rows become
        // the selection before the list is built.
        .task {
            context.adopt(targetIds)
            await context.refreshAvailability()
            destinations = await context.moveDestinations()
        }
    }
}
