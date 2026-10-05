// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// The row under the toolbar while searching: three toggle chips, the "Search parameters…"
/// button and Clear. [ux-spec.md](../../../docs/product/ux-spec.md#search-filters-ws-32).
///
/// It writes ``SearchModel/flags`` and nothing else; the list follows because the model's
/// filter changes, the same path a keystroke takes.
struct SearchFilterBar: View {
    @Bindable var model: SearchModel

    @Environment(\.ncTheme) private var theme

    var body: some View {
        HStack(spacing: theme.metrics.spacing.tight) {
            SearchToggleChip(title: String(localized: "Has attachment"), isOn: $model.flags.withAttachmentsOnly)
            SearchToggleChip(title: String(localized: "Unread"), isOn: $model.flags.unreadOnly)
            SearchToggleChip(title: String(localized: "To me"), isOn: $model.flags.toMeOnly)
            Spacer(minLength: theme.metrics.spacing.tight)
            Button(parametersTitle) { model.isParametersSheetPresented = true }
                .buttonStyle(.tertiary)
                .accessibilityLabel(Text(parametersTitle))
            if model.hasActiveFilters {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.tertiary)
                    .accessibilityLabel(Text("Clear search filters"))
            }
        }
        .padding(.horizontal, theme.metrics.spacing.standard)
        .padding(.vertical, theme.metrics.spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var parametersTitle: String {
        let count = model.activeParameterCount
        return count == 0
            ? String(localized: "Search parameters…")
            : String(localized: "Search parameters (\(count))…")
    }
}

/// An `NCChip` that toggles: `.primary` when on, `.neutral` when off, a button for
/// VoiceOver with the selected trait.
struct SearchToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            NCChip(title, role: isOn ? .primary : .neutral)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
