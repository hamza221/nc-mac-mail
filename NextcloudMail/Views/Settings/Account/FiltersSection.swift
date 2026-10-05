// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8.6: the filter list from the Sieve row, and the editor. A save sends the whole list as
/// one `saveFilters` command (online only, ADR-0068); the server compiles it into the active
/// script, which the command re-reads.
struct FiltersSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    let goTo: (AccountSettingsSection) -> Void

    @State private var editing: MailFilterDraft?
    @State private var deleting: MailFilterDraft?
    @State private var status: SettingsStatus?

    var body: some View {
        Form {
            Section {
                if !account.sieveEnabled {
                    SieveHintCard { goTo(.sieveServer) }
                } else if let filters = model.filters {
                    if filters.isEmpty {
                        Text("No filters yet.").foregroundStyle(.secondary)
                    }
                    ForEach(filters) { filter in
                        row(filter)
                    }
                    Button(String(localized: "New filter")) { editing = MailFilterDraft.new(after: filters) }
                    SettingsStatusLine(status: status)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Hang tight while the filters load")
                    }
                }
            } header: {
                Text("Filters")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { filter in
            MailFilterEditor(model: model, account: account, filter: filter) { saved in
                await save(saved)
            }
            .interactiveDismissDisabled()
        }
        .confirmationDialog(
            String(format: String(localized: "Delete mail filter %@?"), deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { filter in
            Button(String(localized: "Delete filter"), role: .destructive) {
                Task { await delete(filter) }
            }
        } message: { _ in
            Text("Are you sure to delete the mail filter?")
        }
    }

    private func row(_ filter: MailFilterDraft) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(filter.name).font(.headline)
                Text(filter.enable ? "Filter is active" : "Filter is not active")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Edit")) { editing = filter }
            Button(String(localized: "Delete filter"), role: .destructive) { deleting = filter }
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = filter }
    }

    /// Replaces the edited filter, or appends a new one, and sends the list.
    private func save(_ filter: MailFilterDraft) async -> Bool {
        var filters = model.filters ?? []
        if let index = filters.firstIndex(where: { $0.serverId != nil && $0.serverId == filter.serverId }) {
            filters[index] = filter
        } else {
            filters.append(filter)
        }
        let outcome = await model.saveFilters(filters)
        status =
            outcome.isSuccess
            ? .success(String(localized: "Filter saved")) : .failure(String(localized: "Could not save filter"))
        return outcome.isSuccess
    }

    private func delete(_ filter: MailFilterDraft) async {
        let filters = (model.filters ?? []).filter { $0.serverId == nil || $0.serverId != filter.serverId }
        let outcome = await model.saveFilters(filters)
        status =
            outcome.isSuccess
            ? .success(String(localized: "Filter deleted")) : .failure(String(localized: "Could not delete filter"))
    }
}

/// The filter editor sheet. It edits a copy; nothing is sent until Save.
struct MailFilterEditor: View {
    let model: AccountSettingsModel
    let account: AccountRecord
    let save: (MailFilterDraft) async -> Bool

    @State private var draft: MailFilterDraft
    @State private var showingHelp = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session

    init(
        model: AccountSettingsModel, account: AccountRecord, filter: MailFilterDraft,
        save: @escaping (MailFilterDraft) async -> Bool
    ) {
        self.model = model
        self.account = account
        self.save = save
        _draft = State(initialValue: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Filter name"), text: $draft.name)
                    HStack {
                        Picker(String(localized: "Operator"), selection: $draft.operator) {
                            ForEach(MailFilterDraft.Operator.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Button(String(localized: "Help")) { showingHelp = true }
                            .popover(isPresented: $showingHelp) { help }
                    }
                }
                Section {
                    ForEach($draft.conditions) { $condition in
                        conditionRow($condition)
                    }
                    Button(String(localized: "Add condition")) { draft.conditions.append(.init()) }
                } header: {
                    Text("Conditions")
                }
                Section {
                    ForEach($draft.actions) { $action in
                        actionRow($action)
                    }
                    Button(String(localized: "Add action")) { draft.addAction() }
                } header: {
                    Text("Actions")
                }
                Section {
                    TextField(String(localized: "Priority"), value: $draft.priority, format: .number.grouping(.never))
                    Toggle(String(localized: "Enable filter"), isOn: $draft.enable)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                BusyButton(title: String(localized: "Save filter"), isDisabled: !draft.isValid) {
                    var final = draft
                    final.keepStopLast()
                    if await save(final) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 560)
        .navigationTitle(draft.name)
    }

    private var help: some View {
        VStack(alignment: .leading) {
            Text("“contains” matches when the text appears anywhere in the field.")
            Text("“matches” compares the whole field against a pattern: * stands for any text, ? for one character.")
            Text("“is exactly” matches the whole field and nothing else.")
        }
        .padding()
        .frame(width: 320)
    }

    private func conditionRow(_ condition: Binding<MailFilterDraft.Condition>) -> some View {
        HStack {
            Picker(String(localized: "Field"), selection: condition.field) {
                ForEach(MailFilterDraft.Field.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            Picker(String(localized: "Match"), selection: condition.match) {
                ForEach(MailFilterDraft.Match.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            TextField(
                placeholder(condition.wrappedValue.field),
                text: Binding(
                    get: { condition.wrappedValue.values.joined(separator: ", ") },
                    set: { condition.wrappedValue.values = MailFilterDraft.values(from: $0) }
                )
            )
            .labelsHidden()
            Button(String(localized: "Delete condition"), role: .destructive) {
                draft.conditions.removeAll { $0.id == condition.wrappedValue.id }
            }
        }
    }

    private func placeholder(_ field: MailFilterDraft.Field) -> String {
        switch field {
        case .subject: String(localized: "Subject, comma separated")
        case .from: String(localized: "Sender, comma separated")
        case .to: String(localized: "Recipient, comma separated")
        }
    }

    @ViewBuilder
    private func actionRow(_ action: Binding<MailFilterDraft.Action>) -> some View {
        HStack {
            Picker(
                String(localized: "Action"),
                selection: Binding(
                    get: { action.wrappedValue.kind },
                    set: { kind in
                        guard let kind else { return }
                        action.wrappedValue.change(to: kind)
                        draft.keepStopLast()
                    }
                )
            ) {
                ForEach(MailFilterDraft.ActionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                if action.wrappedValue.kind == nil {
                    Text(action.wrappedValue.type).tag(MailFilterDraft.ActionKind?.none)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            switch action.wrappedValue.kind {
            case .addSystemFlag:
                Picker(String(localized: "Flag"), selection: action.value) {
                    Text("Select a flag").tag("")
                    ForEach(MailFilterDraft.SystemFlag.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
            case .addFlag:
                TextField(String(localized: "Flag"), text: action.value).labelsHidden()
            case .fileInto:
                InlineMailboxPicker(
                    title: String(localized: "Folder"),
                    accountId: account.id,
                    store: session.store,
                    selection: Binding(
                        get: { model.localMailboxId(path: action.wrappedValue.value) },
                        set: { local in action.wrappedValue.value = model.mailboxPath(local: local) ?? "" }
                    )
                )
                .labelsHidden()
            case .stop:
                Text("Stop ends all processing").foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            Spacer()
            Button(String(localized: "Delete action"), role: .destructive) {
                draft.actions.removeAll { $0.id == action.wrappedValue.id }
            }
        }
    }
}
