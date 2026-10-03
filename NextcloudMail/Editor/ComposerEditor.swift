// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NextcloudUI
import SwiftUI

/// The whole editor: toolbar, text view, source view, the turn-off-formatting dialog and
/// the trigger suggestions. This is the piece WS-27's composer embeds under its fields.
///
/// The view owns nothing but presentation state; content lives in the ``EditorDocument``
/// the caller holds, so the composer can serialise a draft whether or not this view exists.
struct ComposerEditor: View {
    @Bindable var document: EditorDocument
    var providers = EditorProviders()
    /// Pasted or dropped files, which are attachments, never inline content.
    var onFileDrop: (EditorDroppedFile) -> Void = { _ in }
    /// A mention was accepted; the composer adds the address to To.
    var onMention: (MentionCandidate) -> Void = { _ in }

    @Environment(\.ncTheme) private var theme
    @State private var showingSource = false
    @State private var sourceText = ""
    @State private var confirmingFormattingOff = false
    @State private var mentionCandidates: [MentionCandidate] = []
    @State private var blockCandidates: [EditorTextBlock] = []
    @State private var linkCandidates: [SmartPickerLink] = []

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, showingSource: $showingSource, onToggleFormatting: toggleFormatting)
            Divider()
            if showingSource {
                sourceEditor
            } else {
                RichTextEditor(document: document, onFileDrop: onFileDrop)
                    .overlay(alignment: .topLeading) { triggerSuggestions }
            }
        }
        .onChange(of: showingSource) { _, showing in
            // Entering source mode serialises; leaving it re-imports, which also makes
            // whatever was typed canonical (ADR-0073).
            if showing {
                document.cancelTrigger()
                sourceText = document.html()
            } else {
                document.setHTML(sourceText)
            }
        }
        .confirmationDialog("Turn off formatting", isPresented: $confirmingFormattingOff) {
            Button("Turn off and remove formatting", role: .destructive) { document.disableFormatting() }
            Button("Keep formatting", role: .cancel) {}
        } message: {
            Text("Formatting and images will be removed from this message.")
        }
        .alert(
            "Could not insert image",
            isPresented: Binding(
                get: { document.imageError != nil },
                set: { if !$0 { document.imageError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(document.imageError ?? "")
        }
        .task(id: triggerFingerprint) { await fetchCandidates() }
    }

    // MARK: - Modes

    private func toggleFormatting() {
        if document.mode == .plain {
            document.enableFormatting()
            return
        }
        if showingSource {
            // The source text is about to be discarded with the formatting; fold it in first.
            document.setHTML(sourceText)
            showingSource = false
        }
        if document.hasFormatting {
            confirmingFormattingOff = true
        } else {
            document.disableFormatting()
        }
    }

    private var sourceEditor: some View {
        TextEditor(text: $sourceText)
            .font(.body.monospaced())
            .accessibilityLabel(Text("HTML source"))
    }

    // MARK: - Trigger suggestions

    private var triggerFingerprint: String? {
        guard let trigger = document.trigger else { return nil }
        return "\(trigger.kind.rawValue)\(trigger.query)"
    }

    private func fetchCandidates() async {
        guard let trigger = document.trigger else {
            mentionCandidates = []
            blockCandidates = []
            linkCandidates = []
            return
        }
        switch trigger.kind {
        case .mention:
            mentionCandidates = await providers.mentions?.mentionCandidates(matching: trigger.query) ?? []
        case .textBlock:
            blockCandidates = await providers.textBlocks?.textBlocks(matching: trigger.query) ?? []
        case .smartPicker:
            linkCandidates = await providers.smartPicker?.smartPickerLinks(matching: trigger.query) ?? []
        case .emoji:
            break
        }
    }

    @ViewBuilder private var triggerSuggestions: some View {
        if let trigger = document.trigger, hasCandidates(for: trigger.kind) {
            suggestionList(for: trigger.kind)
                .frame(maxWidth: 320)
                .background(.background, in: RoundedRectangle(cornerRadius: theme.metrics.radius.element))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.metrics.radius.element)
                        .strokeBorder(theme.colors.primarySurface)
                )
                .shadow(radius: theme.metrics.radius.small)
                .offset(x: trigger.caretRect.minX, y: trigger.caretRect.maxY)
                .accessibilityLabel(Text("Suggestions"))
        }
    }

    private func hasCandidates(for kind: TriggerSession.Kind) -> Bool {
        switch kind {
        case .mention: !mentionCandidates.isEmpty
        case .textBlock: !blockCandidates.isEmpty
        case .smartPicker: !linkCandidates.isEmpty
        case .emoji: false
        }
    }

    @ViewBuilder private func suggestionList(for kind: TriggerSession.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .mention:
                ForEach(mentionCandidates.prefix(6)) { candidate in
                    suggestionRow(title: candidate.displayName, subtitle: candidate.email) {
                        document.insertMention(candidate)
                        onMention(candidate)
                    }
                }
            case .textBlock:
                ForEach(blockCandidates.prefix(6)) { block in
                    suggestionRow(title: block.title, subtitle: nil) {
                        document.insertTextBlock(block)
                    }
                }
            case .smartPicker:
                ForEach(linkCandidates.prefix(6)) { link in
                    suggestionRow(title: link.title, subtitle: link.url.absoluteString) {
                        document.insertSmartPickerLink(link)
                    }
                }
            case .emoji:
                EmptyView()
            }
        }
        .padding(theme.metrics.spacing.tight)
    }

    private func suggestionRow(title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.hairline) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(theme.metrics.spacing.tight)
        .accessibilityLabel(Text(subtitle.map { "\(title), \($0)" } ?? title))
    }
}
