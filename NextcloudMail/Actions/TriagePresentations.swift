// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NextcloudUI
import SwiftUI

/// A sheet a triage action needs. Captures the selection it was asked for, so a selection
/// that changes behind the sheet does not change what the sheet acts on.
enum TriagePresentation: Identifiable, Equatable {
    case tags(Selection, accountId: Int64)
    case move(Selection)
    case customSnooze(Selection)

    var id: String {
        switch self {
        case .tags: "tags"
        case .move: "move"
        case .customSnooze: "snooze"
        }
    }
}

extension View {
    /// Hosts every triage sheet, and the notices the web shows as toasts, on the main window.
    ///
    /// One modifier on the window root, because the menu bar opens these sheets and a
    /// `Commands` body has no window of its own to present from. It also hands the context
    /// `openComposer`, which only a view's environment has.
    func triagePresentations(_ context: TriageContext) -> some View {
        modifier(TriagePresentationHost(context: context))
    }
}

private struct TriagePresentationHost: ViewModifier {
    @Bindable var context: TriageContext
    @Environment(\.openComposer) private var openComposer

    func body(content: Content) -> some View {
        content
            .sheet(item: $context.presentation) { presentation in
                switch presentation {
                case .tags(let selection, let accountId):
                    TagEditorSheet(context: context, selection: selection, accountId: accountId)
                case .move(let selection):
                    MailboxPicker(context: context, selection: selection) { context.presentation = nil }
                case .customSnooze(let selection):
                    CustomSnoozeSheet(context: context, selection: selection)
                }
            }
            .alert(
                context.actions.notice ?? "",
                isPresented: Binding(
                    get: { context.actions.notice != nil },
                    set: { if !$0 { context.actions.notice = nil } }
                )
            ) {
                Button(String(localized: "OK")) { context.actions.notice = nil }
            }
            .onAppear {
                let open = openComposer
                context.openComposer = { open($0) }
            }
    }
}

// MARK: - Custom snooze

/// "Set custom snooze" (§4.4): a date and time, not before now.
private struct CustomSnoozeSheet: View {
    let context: TriageContext
    let selection: Selection

    @State private var date = Date.now.addingTimeInterval(60 * 60)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Snooze until")
                .font(.headline)
            DatePicker(
                String(localized: "Snooze until"),
                selection: $date,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Set custom snooze")) {
                    let until = max(date, .now)
                    dismiss()
                    Task { await context.snooze(selection, until: until) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
    }
}

// MARK: - Tags

/// The tag modal (§4.8): set and unset on every envelope it was opened for, add, edit
/// name or colour, delete.
private struct TagEditorSheet: View {
    let context: TriageContext
    let selection: Selection
    let accountId: Int64

    @State private var tags: [TagRecord] = []
    @State private var onAll: Set<String> = []
    @State private var isAdding = false
    @State private var newName = ""
    @State private var editing: TagRecord?
    @State private var editName = ""
    @State private var editColor = Color.accentColor
    @State private var deleting: TagRecord?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    private var ordered: [TagRecord] { TagRules.ordered(tags, setOnAll: onAll) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                    let defaults = ordered.filter(TagRules.isDefault)
                    let others = ordered.filter { !TagRules.isDefault($0) }
                    if !defaults.isEmpty {
                        Text("Add default tags").font(.subheadline.weight(.semibold))
                        ForEach(defaults, id: \.id) { row($0) }
                    }
                    Text("Add tag").font(.subheadline.weight(.semibold))
                    ForEach(others, id: \.id) { row($0) }
                }
            }
            .frame(maxHeight: Self.listHeight)
            addTag
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: Self.width)
        .task {
            do {
                for try await latest in context.actions.store.observeTags(accountId: accountId) {
                    tags = latest
                    onAll = await context.actions.labelsOnAll(selection)
                }
            } catch {
                MessageActions.logger.error("tag observation ended: \(String(describing: error), privacy: .public)")
            }
        }
        .confirmationDialog(
            String(localized: "Delete tag"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { tag in
            Button(String(localized: "Delete tag"), role: .destructive) {
                Task { await context.actions.deleteTag(tag) }
            }
        } message: { _ in
            Text("The tag will be deleted from all messages.")
        }
    }

    @ViewBuilder
    private func row(_ tag: TagRecord) -> some View {
        if editing?.id == tag.id {
            editRow(tag)
        } else {
            let isSet = onAll.contains(tag.imapLabel)
            HStack(spacing: theme.metrics.spacing.tight) {
                NCChip(TagRules.displayName(of: tag), tint: MessageListRow.tint(tag.color))
                Spacer(minLength: 0)
                Button(isSet ? String(localized: "Unset tag") : String(localized: "Set tag")) {
                    Task {
                        await context.actions.setTag(tag, present: !isSet, on: selection)
                        onAll = await context.actions.labelsOnAll(selection)
                    }
                }
                .buttonStyle(.secondary)
                Menu {
                    Button(String(localized: "Edit name or color")) {
                        editName = tag.displayName
                        editColor = tag.color.flatMap { NCRGB(hex: $0)?.color } ?? .accentColor
                        editing = tag
                    }
                    if !TagRules.isDefault(tag) {
                        Button(String(localized: "Delete tag"), role: .destructive) { deleting = tag }
                    }
                } label: {
                    MailSymbol.more.view(size: .small, label: .text("Actions for \(tag.displayName)"))
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func editRow(_ tag: TagRecord) -> some View {
        let error = TagRules.validate(editName, editing: tag, among: tags)
        return VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            HStack(spacing: theme.metrics.spacing.tight) {
                ColorPicker(String(localized: "Color"), selection: $editColor, supportsOpacity: false)
                    .labelsHidden()
                TextField(String(localized: "Tag name"), text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveEdit(tag, error: error) }
                Button(String(localized: "Save")) { saveEdit(tag, error: error) }
                    .disabled(error != nil)
                Button(String(localized: "Cancel")) { editing = nil }
            }
            if let error { validation(error) }
        }
    }

    private func saveEdit(_ tag: TagRecord, error: TagRules.ValidationError?) {
        guard error == nil else { return }
        let color = Self.hex(editColor) ?? tag.color ?? TagRules.randomColor()
        editing = nil
        Task { await context.actions.updateTag(tag, displayName: editName, color: color) }
    }

    @ViewBuilder
    private var addTag: some View {
        if isAdding {
            let error = TagRules.validate(newName, among: tags)
            VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
                TextField(String(localized: "Tag name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard error == nil else { return }
                        let name = newName
                        newName = ""
                        isAdding = false
                        Task {
                            await context.actions.createTag(
                                accountId: accountId, displayName: name, color: TagRules.randomColor())
                        }
                    }
                if !newName.isEmpty, let error { validation(error) }
            }
        } else {
            Button(String(localized: "Add tag")) { isAdding = true }
                .buttonStyle(.tertiary)
        }
    }

    private func validation(_ error: TagRules.ValidationError) -> some View {
        Text(error.message)
            .font(.callout)
            .foregroundStyle(theme.colors.error.element)
    }

    /// The picked colour as `#rrggbb`, in sRGB as the server stores it.
    private static func hex(_ color: Color) -> String? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return NCRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent).hexString
    }

    /// Sheet shape: window chrome, not a theme metric.
    private static let width = 380.0
    private static let listHeight = 360.0
}
