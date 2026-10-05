// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI

/// §8.7: the account's quick actions and their editor. Every write is queued, so a new
/// action and its steps work offline under placeholder ids (ADR-0081).
struct QuickActionsSection: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    /// The editor's subject: a fresh draft, or a saved action's.
    private struct Editing: Identifiable {
        let id = UUID()
        let draft: QuickActionDraft
        let original: QuickActionDraft?
    }

    @State private var editing: Editing?
    @State private var status: SettingsStatus?

    var body: some View {
        Form {
            Section {
                if model.quickActions.isEmpty {
                    Text("No quick actions yet.").foregroundStyle(.secondary)
                }
                ForEach(model.quickActions, id: \.remoteId) { action in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(action.name).font(.headline)
                            Text(
                                model.steps(of: action).map { QuickActionDraft.title(of: $0.name) }.joined(
                                    separator: ", ")
                            )
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Edit")) { edit(action) }
                        Button(String(localized: "Delete"), role: .destructive) {
                            Task { await delete(action) }
                        }
                    }
                }
                Button(String(localized: "Add quick action")) {
                    editing = Editing(draft: QuickActionDraft(), original: nil)
                }
                SettingsStatusLine(status: status)
            } header: {
                Text("Quick actions")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { subject in
            QuickActionEditor(model: model, account: account, draft: subject.draft, original: subject.original)
        }
    }

    private func edit(_ action: QuickActionRecord) {
        let draft = QuickActionDraft(action: action, steps: model.steps(of: action))
        editing = Editing(draft: draft, original: draft)
    }

    private func delete(_ action: QuickActionRecord) async {
        let deleted = await model.perform(.deleteQuickAction(quickActionRemoteId: action.remoteId))
        status =
            deleted
            ? .success(String(localized: "Quick action deleted"))
            : .failure(String(localized: "Failed to delete quick action"))
    }
}

/// The quick action sheet: name, the ordered steps under the terminal-step rules of
/// ``QuickActionDraft``, and Save.
struct QuickActionEditor: View {
    let model: AccountSettingsModel
    let account: AccountRecord

    @State private var draft: QuickActionDraft
    /// What the server holds, so Save writes only changed steps.
    @State private var original: QuickActionDraft?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session

    init(model: AccountSettingsModel, account: AccountRecord, draft: QuickActionDraft, original: QuickActionDraft?) {
        self.model = model
        self.account = account
        _draft = State(initialValue: draft)
        _original = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $draft.name)
                }
                Section {
                    ForEach($draft.steps) { $step in
                        stepRow($step)
                    }
                    Menu(String(localized: "Add another action")) {
                        ForEach(draft.addableStepNames, id: \.self) { name in
                            Button(QuickActionDraft.title(of: name)) { draft.add(name) }
                        }
                    }
                    .fixedSize()
                } header: {
                    Text("Do the following actions")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                BusyButton(title: String(localized: "Save"), isDisabled: !draft.canSave) {
                    if await model.save(draft, original: original) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func stepRow(_ step: Binding<QuickActionDraft.Step>) -> some View {
        let id = step.wrappedValue.id
        return HStack {
            Text(QuickActionDraft.title(of: step.wrappedValue.name))
                .frame(minWidth: 140, alignment: .leading)
            switch step.wrappedValue.name {
            case QuickActionStep.applyTag:
                Picker(String(localized: "Tag"), selection: step.tagRemoteId) {
                    Text("Select a tag").tag(Int64?.none)
                    ForEach(tags, id: \.remoteId) { tag in
                        Text(TagRules.displayName(of: tag)).tag(Int64?.some(tag.remoteId))
                    }
                }
                .labelsHidden()
            case QuickActionStep.moveThread:
                InlineMailboxPicker(
                    title: String(localized: "Folder"),
                    accountId: account.id,
                    store: session.store,
                    selection: Binding(
                        get: { model.localMailboxId(remote: step.wrappedValue.mailboxRemoteId) },
                        set: { step.wrappedValue.mailboxRemoteId = model.remoteMailboxId(local: $0) }
                    )
                )
                .labelsHidden()
            default:
                EmptyView()
            }
            Spacer()
            // Arrows as text: the catalogue has no up/down glyph, and AGENTS.md keeps
            // system-symbol images inside MailSymbol.swift.
            Button("↑") { draft.move(id, by: -1) }
                .disabled(!draft.canMove(id, by: -1))
                .help(String(localized: "Move up"))
                .accessibilityLabel(String(localized: "Move up"))
            Button("↓") { draft.move(id, by: 1) }
                .disabled(!draft.canMove(id, by: 1))
                .help(String(localized: "Move down"))
                .accessibilityLabel(String(localized: "Move down"))
            Button(role: .destructive) {
                remove(id)
            } label: {
                MailSymbol.remove.view(size: .small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove"))
            .accessibilityLabel(String(localized: "Remove"))
        }
    }

    /// The tags a step may apply: not Important, not the hidden system labels.
    private var tags: [TagRecord] {
        model.tags.filter(TagRules.isListed)
    }

    /// The web deletes a saved step as soon as its ✕ is pressed; the original forgets it so
    /// Save does not try to write it again.
    private func remove(_ id: QuickActionDraft.Step.ID) {
        guard let step = draft.remove(id) else { return }
        guard step.remoteId != nil else { return }
        original?.steps.removeAll { $0.remoteId == step.remoteId }
        Task { await model.deleteStep(step, of: draft.remoteId) }
    }
}
