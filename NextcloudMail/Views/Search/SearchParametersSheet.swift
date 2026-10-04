// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import OSLog
import SwiftUI

/// The "Search parameters" sheet: subject, body, date range, from, to, cc, bcc, tags and the
/// four toggles. [ux-spec.md](../../../docs/product/ux-spec.md#search-filters-ws-32).
///
/// Edits a draft, not the model: nothing reaches the list until Search is pressed, so a
/// half-typed address never runs as a query, and Cancel really does cancel.
struct SearchParametersSheet: View {
    let model: SearchModel

    @State private var draft: SearchQuery.Parameters
    @State private var flags: SearchQuery.FlagFilter
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var tags: [SearchTagOption] = []

    @Environment(\.ncTheme) private var theme

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "search")

    init(model: SearchModel) {
        self.model = model
        let parameters = model.parameters
        _draft = State(initialValue: parameters)
        _flags = State(initialValue: model.flags)
        let days = SearchDayRange(sentAfter: parameters.sentAfter, sentBefore: parameters.sentBefore)
        _hasStart = State(initialValue: days.start != nil)
        _hasEnd = State(initialValue: days.end != nil)
        _startDay = State(initialValue: days.start ?? .now)
        _endDay = State(initialValue: days.end ?? .now)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Text") {
                    TextField("Subject", text: $draft.subject)
                    TextField("Body", text: $draft.body)
                }
                Section("Date") {
                    Toggle("After", isOn: $hasStart)
                    if hasStart {
                        DatePicker("Start", selection: $startDay, displayedComponents: .date)
                    }
                    Toggle("Before", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("End", selection: $endDay, displayedComponents: .date)
                    }
                }
                Section("People") {
                    SearchAddressField(title: String(localized: "From"), addresses: fromBinding, limit: 1, model: model)
                    SearchAddressField(title: String(localized: "To"), addresses: $draft.to, limit: nil, model: model)
                    SearchAddressField(title: String(localized: "Cc"), addresses: $draft.cc, limit: nil, model: model)
                    SearchAddressField(title: String(localized: "Bcc"), addresses: $draft.bcc, limit: nil, model: model)
                }
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags) { tag in
                            Toggle(tag.displayName, isOn: tagBinding(tag.imapLabel))
                        }
                    }
                }
                Section("Only messages that are") {
                    Toggle("Important", isOn: $flags.importantOnly)
                    Toggle("Favorite", isOn: $flags.starredOnly)
                    Toggle("Has attachments", isOn: $flags.withAttachmentsOnly)
                    Toggle("Mentions me", isOn: $flags.mentionsMeOnly)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: theme.metrics.spacing.standard) {
                Button("Reset") { reset() }
                    .buttonStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { model.isParametersSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.tertiary)
                Button("Search") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primary)
            }
            .padding(theme.metrics.spacing.standard)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 520)
        .task {
            do {
                for try await fresh in model.tagOptions() { tags = fresh }
            } catch {
                Self.logger.error("tag options stopped: \(String(describing: error), privacy: .private)")
            }
        }
    }

    // MARK: - Bindings

    /// From is one address at most, kept as an optional in the query and as a list of zero
    /// or one here so it shares the address field.
    private var fromBinding: Binding<[String]> {
        Binding(
            get: { draft.from.map { [$0] } ?? [] },
            set: { draft.from = $0.last }
        )
    }

    private func tagBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { draft.tags.contains(label) },
            set: { isOn in
                draft.tags.removeAll { $0 == label }
                if isOn { draft.tags.append(label) }
            }
        )
    }

    // MARK: - Actions

    private func apply() {
        var parameters = draft
        let range = SearchDayRange(start: hasStart ? startDay : nil, end: hasEnd ? endDay : nil)
        parameters.sentAfter = range.sentAfter
        parameters.sentBefore = range.sentBefore
        model.apply(parameters: parameters, flags: flags)
    }

    private func reset() {
        draft = SearchQuery.Parameters()
        flags.importantOnly = false
        flags.starredOnly = false
        flags.withAttachmentsOnly = false
        flags.mentionsMeOnly = false
        hasStart = false
        hasEnd = false
    }
}

/// A list of addresses: chips for what is entered, a field to add one, and suggestions
/// from mirrored mail while typing. `limit: 1` makes a new entry replace the old one.
struct SearchAddressField: View {
    let title: String
    @Binding var addresses: [String]
    let limit: Int?
    let model: SearchModel

    @State private var entry = ""
    @State private var suggestions: [SearchAddressSuggestion] = []

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            TextField(title, text: $entry, prompt: Text("name@example.com"))
                .onSubmit { add(entry) }
                .accessibilityLabel(Text(title))
            if !addresses.isEmpty {
                HStack(spacing: theme.metrics.spacing.tight) {
                    ForEach(addresses, id: \.self) { address in
                        NCChip(address, onRemove: { addresses.removeAll { $0 == address } })
                    }
                }
            }
            ForEach(suggestions) { suggestion in
                Button {
                    add(suggestion.email)
                } label: {
                    Text(suggestion.label.map { "\($0) <\(suggestion.email)>" } ?? suggestion.email)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Add \(suggestion.email)"))
            }
        }
        .task(id: entry) {
            suggestions = await model.addressSuggestions(for: entry)
                .filter { suggestion in
                    !addresses.contains { $0.caseInsensitiveCompare(suggestion.email) == .orderedSame }
                }
        }
    }

    private func add(_ raw: String) {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        entry = ""
        guard !address.isEmpty,
            !addresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame })
        else { return }
        if limit == 1 {
            addresses = [address]
        } else {
            addresses.append(address)
        }
    }
}

/// The sheet's whole days and the query's half-open instants, in the user's calendar.
///
/// The start day's midnight is `sentAfter`; the midnight after the end day is `sentBefore`,
/// so both days are included and nothing on a boundary is counted twice.
struct SearchDayRange: Equatable {
    var start: Date?
    var end: Date?
    var calendar = Calendar.current

    init(start: Date?, end: Date?, calendar: Calendar = .current) {
        self.start = start
        self.end = end
        self.calendar = calendar
    }

    /// The days a query's bounds describe, for reopening the sheet.
    init(sentAfter: Int64?, sentBefore: Int64?, calendar: Calendar = .current) {
        self.calendar = calendar
        start = sentAfter.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        end = sentBefore.map { Date(timeIntervalSince1970: TimeInterval($0 - 1)) }
    }

    var sentAfter: Int64? {
        start.map { Int64(calendar.startOfDay(for: $0).timeIntervalSince1970) }
    }

    var sentBefore: Int64? {
        guard let end else { return nil }
        let midnight = calendar.startOfDay(for: end)
        let next = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        return Int64(next.timeIntervalSince1970)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sentAfter == rhs.sentAfter && lhs.sentBefore == rhs.sentBefore
    }
}
