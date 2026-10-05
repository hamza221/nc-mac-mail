// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailCore
import NCMailStore
import NextcloudUI
import SwiftUI

/// Merge two contacts: which card to keep, a radio per single-value property the cards
/// disagree on, a checkbox per address/number/link, and groups combined by default. Merge
/// queues one `contactPut` over the kept card and one `contactDelete` of the other.
struct ContactMergeSheet: View {
    let sessionId: String
    let first: ContactRecord
    let second: ContactRecord

    @Environment(ContactsBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var keepsFirst: Bool
    @State private var plan: ContactMergePlan?
    @State private var status: String?

    init(sessionId: String, first: ContactRecord, second: ContactRecord) {
        self.sessionId = sessionId
        self.first = first
        self.second = second
        // The fuller card is the better default to keep: fewer choices to make.
        let count = { (record: ContactRecord) in (try? VCardParser.parse(record.vcard).first?.properties.count) ?? 0 }
        _keepsFirst = State(initialValue: count(first) >= count(second))
    }

    private var kept: ContactRecord { keepsFirst ? first : second }
    private var other: ContactRecord { keepsFirst ? second : first }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Merge contacts").font(.headline)
            Picker("Keep", selection: $keepsFirst) {
                Text(Self.name(first)).tag(true)
                Text(Self.name(second)).tag(false)
            }
            .pickerStyle(.segmented)
            Text("The other contact is deleted. Anything this sheet does not list stays as the kept contact has it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let plan {
                form(plan)
            } else {
                Text("These contacts cannot be read.").foregroundStyle(.secondary)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { merge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 560)
        .frame(minHeight: 420)
        .onAppear(perform: rebuild)
        .onChange(of: keepsFirst) { _, _ in rebuild() }
    }

    @ViewBuilder
    private func form(_ plan: ContactMergePlan) -> some View {
        Form {
            if !plan.singles.isEmpty {
                Section("Choose one") {
                    ForEach(Array(plan.singles.enumerated()), id: \.element.id) { index, choice in
                        Picker(Self.title(choice.name), selection: binding(single: index)) {
                            Text(choice.kept.map(ContactMergePlan.display) ?? String(localized: "None"))
                                .tag(ContactMergePlan.Side.kept)
                            Text(choice.other.map(ContactMergePlan.display) ?? String(localized: "None"))
                                .tag(ContactMergePlan.Side.other)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
            }
            if !plan.multis.isEmpty {
                Section("Keep") {
                    ForEach(Array(plan.multis.enumerated()), id: \.element.id) { index, row in
                        Toggle(isOn: binding(multi: index)) {
                            HStack {
                                Text(Self.title(row.name)).foregroundStyle(.secondary)
                                Text(ContactMergePlan.display(row.property))
                                if row.side == .other {
                                    Text("from \(Self.name(other))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if !plan.kept.categories.isEmpty || !plan.other.categories.isEmpty {
                Section("Groups") {
                    Toggle("Combine groups", isOn: binding(\.combinesGroups))
                        .toggleStyle(.checkbox)
                    Text(
                        plan.resultingGroups.isEmpty
                            ? String(localized: "None") : plan.resultingGroups.joined(separator: ", ")
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(single index: Int) -> Binding<ContactMergePlan.Side> {
        Binding(get: { plan?.singles[index].pick ?? .kept }, set: { plan?.singles[index].pick = $0 })
    }

    private func binding(multi index: Int) -> Binding<Bool> {
        Binding(get: { plan?.multis[index].include ?? false }, set: { plan?.multis[index].include = $0 })
    }

    private func binding(_ path: WritableKeyPath<ContactMergePlan, Bool>) -> Binding<Bool> {
        Binding(get: { plan?[keyPath: path] ?? false }, set: { plan?[keyPath: path] = $0 })
    }

    private func rebuild() {
        guard let keptCard = try? VCardParser.parse(kept.vcard).first,
            let otherCard = try? VCardParser.parse(other.vcard).first
        else {
            plan = nil
            return
        }
        plan = ContactMergePlan(kept: keptCard, other: otherCard)
    }

    private func merge() {
        guard let plan else { return }
        let kept = kept
        let other = other
        Task {
            guard let actions = browser.actions(sessionId: sessionId) else {
                status = AddressBookActions.message(for: AddressBookActions.Failure.noQueue)
                return
            }
            do {
                try await AddressBookActions(actions).merge(
                    plan, kept: kept, other: other, books: browser.login(sessionId).books)
                if let id = kept.id { browser.reveal(id) }
                dismiss()
            } catch {
                status = AddressBookActions.message(for: error)
            }
        }
    }

    static func name(_ record: ContactRecord) -> String {
        record.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Unnamed contact")
    }

    /// The detail pane's labels for the properties the merge lists.
    static func title(_ name: String) -> String {
        switch name {
        case "FN": String(localized: "Display name")
        case "N": String(localized: "Name")
        case "NICKNAME": String(localized: "Nickname")
        case "ORG": String(localized: "Organization")
        case "TITLE": String(localized: "Title")
        case "ROLE": String(localized: "Role")
        case "BDAY": String(localized: "Birthday")
        case "ANNIVERSARY": String(localized: "Anniversary")
        case "GENDER": String(localized: "Gender")
        case "NOTE": String(localized: "Notes")
        case "PHOTO": String(localized: "Picture")
        case "EMAIL": String(localized: "Email")
        case "TEL": String(localized: "Phone")
        case "ADR": String(localized: "Address")
        case "URL": String(localized: "Website")
        case "IMPP": String(localized: "Instant messaging")
        case "X-SOCIALPROFILE": String(localized: "Social network")
        case "RELATED": String(localized: "Related")
        default: name
        }
    }
}
