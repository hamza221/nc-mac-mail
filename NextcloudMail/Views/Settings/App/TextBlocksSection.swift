// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

/// §7.1: the login's own text blocks, the ones shared with it, and the editor sheet.
struct TextBlocksSection: View {
    @Environment(AppSettingsModel.self) private var model

    @State private var editing: Editing?
    @State private var viewing: ViewedBlock?

    /// What the editor sheet shows: a new block, or one of mine.
    enum Editing: Identifiable {
        case new
        case existing(TextBlockRecord)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let block): "block:\(block.id ?? block.remoteId)"
            }
        }
    }

    var body: some View {
        Section {
            SettingsLoginPicker(model: model)
            if model.ownTextBlocks.isEmpty {
                Text("No text blocks available")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.ownTextBlocks, id: \.remoteId) { block in
                row(block)
            }
            Button(String(localized: "New text block")) { editing = .new }
        } header: {
            Text("Text blocks")
        } footer: {
            Text("Reusable pieces of text you can insert while writing a message.")
        }
        .sheet(item: $editing) { editing in
            TextBlockEditorSheet(editing: editing)
                .environment(model)
        }
        .sheet(item: $viewing) { viewed in
            TextBlockViewer(block: viewed.block)
        }

        if !model.sharedTextBlocks.isEmpty {
            Section {
                ForEach(model.sharedTextBlocks, id: \.remoteId) { block in
                    Button {
                        viewing = ViewedBlock(block: block)
                    } label: {
                        summary(block)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Shared with me")
            }
        }
    }

    private func row(_ block: TextBlockRecord) -> some View {
        HStack {
            summary(block)
            if !model.shares(of: block).isEmpty {
                MailSymbol.shared.view(size: .small)
                    .foregroundStyle(.secondary)
            }
            SettingsIconButton(
                symbol: .edit, label: String(format: String(localized: "Edit %@"), block.title)
            ) { editing = .existing(block) }
            SettingsIconButton(
                symbol: .trash, label: String(format: String(localized: "Delete %@"), block.title)
            ) { Task { await model.deleteTextBlock(block) } }
        }
    }

    private func summary(_ block: TextBlockRecord) -> some View {
        VStack(alignment: .leading) {
            Text(block.title)
            Text(TextBlockFormatting.preview(block.content))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct ViewedBlock: Identifiable {
        let block: TextBlockRecord
        var id: Int64 { block.remoteId }
    }
}

/// A block someone else shared: read only, as in the web.
private struct TextBlockViewer: View {
    let block: TextBlockRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text(block.title).font(.headline)
            if let owner = block.ownerId {
                Text(String(format: String(localized: "Shared by %@"), owner))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(TextBlockFormatting.preview(block.content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 480, height: 320)
    }
}

/// "New text block" and the edit sheet: title, the composer's editor, and — for a block
/// that already exists — its shares.
private struct TextBlockEditorSheet: View {
    let editing: TextBlocksSection.Editing

    @Environment(AppSettingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme

    @State private var title = ""
    @State private var document = EditorDocument()
    @State private var hasContent = false
    @State private var term = ""
    @State private var status: SettingsStatus?

    private var block: TextBlockRecord? {
        guard case .existing(let original) = editing else { return nil }
        // The live row, so shares added from this sheet show at once.
        return model.ownTextBlocks.first { $0.id == original.id } ?? original
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text(block == nil ? String(localized: "New text block") : String(localized: "Edit text block"))
                .font(.headline)
            TextField(String(localized: "Title of the text block"), text: $title)
            ComposerEditor(document: document)
                .frame(minHeight: 180)
                .border(.separator)
            if let block {
                shares(block)
            }
            SettingsStatusLine(status: status)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Ok")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(theme.metrics.spacing.comfortable)
        .frame(width: 560)
        .frame(minHeight: block == nil ? 360 : 560)
        .onAppear(perform: load)
        .onDisappear { model.clearSharees() }
        // Typing moves the caret, which is what the document publishes; the plain text is
        // cheap to read, unlike serialising HTML on every keystroke.
        .onChange(of: document.selection) { _, _ in
            hasContent = !document.plainText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && hasContent
    }

    @ViewBuilder
    private func shares(_ block: TextBlockRecord) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Text("Shares").font(.subheadline.weight(.semibold))
            TextField(String(localized: "Search for users or groups"), text: $term)
                .onChange(of: term) { _, value in model.searchSharees(value, for: block) }
            ForEach(model.sharees) { sharee in
                Button {
                    Task { await share(block, with: sharee) }
                } label: {
                    HStack {
                        (sharee.type == "group" ? MailSymbol.group : MailSymbol.account).view(size: .small)
                        Text(sharee.displayName)
                        Text(sharee.shareWith).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(model.shares(of: block), id: \.shareWith) { share in
                HStack {
                    (share.type == "group" ? MailSymbol.group : MailSymbol.account).view(size: .small)
                    Text(share.displayName ?? share.shareWith)
                    Spacer()
                    SettingsIconButton(
                        symbol: .remove,
                        label: String(format: String(localized: "Remove %@"), share.displayName ?? share.shareWith)
                    ) { Task { await unshare(block, share) } }
                }
            }
        }
    }

    private func load() {
        guard let block else { return }
        title = block.title
        document.setHTML(block.content)
        hasContent = !TextBlockFormatting.preview(block.content).isEmpty
    }

    private func save() async {
        let html = document.html()
        let saved =
            if let block {
                await model.updateTextBlock(block, title: title, content: html)
            } else {
                await model.createTextBlock(title: title, content: html)
            }
        if saved { dismiss() }
    }

    private func share(_ block: TextBlockRecord, with sharee: ShareeSuggestion) async {
        guard await model.share(block, with: sharee) else { return }
        term = ""
        model.clearSharees()
        status = .success(String(format: String(localized: "Text block shared with %@"), sharee.displayName))
    }

    private func unshare(_ block: TextBlockRecord, _ share: TextBlockShareRecord) async {
        guard await model.unshare(block, share: share) else { return }
        status = .success(
            String(format: String(localized: "Share deleted for %@"), share.displayName ?? share.shareWith))
    }
}
