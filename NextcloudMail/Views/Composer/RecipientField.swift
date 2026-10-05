// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// To, Cc or Bcc: chips for the addresses so far, a text field for the next one, and
/// WS-26's suggestions under it (§6.4).
///
/// Not `NCUserPicker`: that picks from a fixed candidate pool in a `List`, while a mail
/// field takes free-typed addresses, pasted lists and suggestions that arrive while the
/// user types (filed in library-feedback.md). The chips are `NCChip`.
struct RecipientField: View {
    let label: String
    let addresses: [ComposerAddress]
    let provider: RecipientSuggestionProvider?
    /// Addresses outside the organisation are drawn red when this is non-nil (§6.4,
    /// `internal-addresses`).
    let isInternal: ((ComposerAddress) -> Bool)?
    let onAdd: ([ComposerAddress]) -> Void
    let onRemove: (ComposerAddress) -> Void
    var trailing: AnyView?

    @State private var text = ""
    @State private var suggestions: [RecipientSuggestion] = []
    @State private var highlighted = 0
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.ncTheme) private var theme

    /// Collapsed fields show this many chips and a "+N".
    private static let collapsedCount = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metrics.spacing.standard) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            FlowLayout(spacing: theme.metrics.spacing.tight) {
                ForEach(visibleAddresses, id: \.key) { address in
                    chip(address)
                }
                if hiddenCount > 0 {
                    Button("+\(hiddenCount)") { expanded = true }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Show \(hiddenCount) more recipients"))
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(minWidth: 160)
                    .accessibilityLabel(Text(label))
                    .onSubmit { acceptHighlightedOrCommit() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) {
                        suggestions = []
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard text.isEmpty, let last = addresses.last else { return .ignored }
                        onRemove(last)
                        return .handled
                    }
                    .onChange(of: text) { _, newValue in
                        // A pasted list, or a typed separator, becomes chips straight away.
                        if newValue.contains(",") || newValue.contains(";") || newValue.contains("\n") {
                            commit()
                        }
                    }
                    .onChange(of: focused) { _, isFocused in
                        if isFocused {
                            expanded = true
                        } else {
                            commit()
                            suggestions = []
                            expanded = false
                        }
                    }
                    .popover(isPresented: showsSuggestions, arrowEdge: .bottom) { suggestionList }
            }
            if let trailing { trailing }
        }
        .task(id: text) { await loadSuggestions() }
    }

    private var visibleAddresses: [ComposerAddress] {
        expanded || focused ? addresses : Array(addresses.prefix(Self.collapsedCount))
    }

    private var hiddenCount: Int { addresses.count - visibleAddresses.count }

    private var showsSuggestions: Binding<Bool> {
        Binding(
            get: { focused && !suggestions.isEmpty && !text.trimmingCharacters(in: .whitespaces).isEmpty },
            set: { if !$0 { suggestions = [] } }
        )
    }

    private func chip(_ address: ComposerAddress) -> some View {
        let external = isInternal.map { !$0(address) } ?? false
        return NCChip(
            address.displayName,
            role: !address.isValid || external ? .error : .neutral,
            onRemove: { onRemove(address) }
        )
        .help(address.email)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    accept(suggestion)
                } label: {
                    HStack(spacing: theme.metrics.spacing.standard) {
                        NCAvatar(displayName: suggestion.displayName, size: .small, label: .decorative)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: suggestion.displayName)
                            if let email = suggestion.email, email != suggestion.displayName {
                                Text(verbatim: email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.metrics.spacing.standard)
                    .padding(.vertical, theme.metrics.spacing.tight)
                    .background(
                        index == highlighted ? AnyShapeStyle(theme.colors.primarySurface) : AnyShapeStyle(.clear)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 280)
        .padding(.vertical, theme.metrics.spacing.tight)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let count = min(suggestions.count, 8)
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func acceptHighlightedOrCommit() {
        if showsSuggestions.wrappedValue, suggestions.indices.contains(highlighted) {
            accept(suggestions[highlighted])
        } else {
            commit()
        }
    }

    private func accept(_ suggestion: RecipientSuggestion) {
        let expandedAddresses = suggestion.expandedAddresses.map { ComposerAddress(email: $0.email, label: $0.label) }
        if !expandedAddresses.isEmpty {
            onAdd(expandedAddresses)
        } else if let email = suggestion.email {
            onAdd([ComposerAddress(email: email, label: suggestion.label)])
        }
        text = ""
        suggestions = []
    }

    /// Valid addresses become chips; anything invalid stays in the field to be fixed (§6.4).
    private func commit() {
        let parsed = AddressParser.parseList(text)
        guard !parsed.isEmpty else {
            if text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;\n")).isEmpty { text = "" }
            return
        }
        let valid = parsed.filter(\.isValid)
        let invalid = parsed.filter { !$0.isValid }
        if !valid.isEmpty { onAdd(valid) }
        text = invalid.map(\.formatted).joined(separator: ", ")
    }

    private func loadSuggestions() async {
        highlighted = 0
        let term = text.trimmingCharacters(in: .whitespaces)
        guard focused, !term.isEmpty, let provider else {
            suggestions = []
            return
        }
        // The web client waits 500 ms before asking the server; local results come at once
        // and the provider merges the server's answer when its rows land.
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let present = Set(addresses.map(\.key))
        for await list in provider.suggestions(matching: term) {
            suggestions = list.filter { suggestion in
                guard let email = suggestion.email?.lowercased() else { return !suggestion.expandedAddresses.isEmpty }
                return !present.contains(email)
            }
        }
    }
}

/// Chips that wrap onto as many lines as they need — the layout a recipient field with
/// twenty addresses wants, and one NextcloudUI does not have (library-feedback.md).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                // The last item of a row (the text field) takes what is left of the line.
                let isLastOverall = index == subviews.count - 1
                let width = isLastOverall ? max(size.width, bounds.maxX - x) : size.width
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed =
                rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
