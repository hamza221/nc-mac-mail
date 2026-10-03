// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

#if DEBUG
import NextcloudUI
import SwiftUI

/// A debug-only bench for the editor: the full `ComposerEditor` with demo providers, the
/// live serialised HTML underneath, and a dropped-file log. Never part of a release build;
/// WS-27 replaces it with the real composer window.
struct EditorPlayground: View {
    @State private var document = EditorDocument()
    @State private var serialized = ""
    @State private var droppedFiles: [String] = []

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VSplitView {
            ComposerEditor(
                document: document,
                providers: EditorProviders(
                    mentions: PlaygroundMentions(),
                    textBlocks: PlaygroundTextBlocks(),
                    smartPicker: PlaygroundSmartPicker()),
                onFileDrop: { dropped in
                    switch dropped {
                    case .url(let url): droppedFiles.append(url.lastPathComponent)
                    case .data(_, let name): droppedFiles.append(name)
                    }
                },
                onMention: { droppedFiles.append("mention → \($0.email)") }
            )
            .frame(minHeight: 240)

            VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
                HStack {
                    Text("Serialised HTML").font(.headline)
                    Spacer()
                    Button("Refresh") { serialized = document.html() }
                        .buttonStyle(.secondary)
                        .accessibilityLabel(Text("Refresh serialised HTML"))
                }
                ScrollView {
                    Text(serialized)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !droppedFiles.isEmpty {
                    Text("Attachments: \(droppedFiles.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(theme.metrics.spacing.loose)
            .frame(minHeight: 120)
        }
    }
}

/// Canned data so the triggers can be exercised without WS-26/WS-27.
private final class PlaygroundMentions: MentionProvider {
    func mentionCandidates(matching query: String) async -> [MentionCandidate] {
        [
            MentionCandidate(displayName: "Lorelai Gilmore", email: "lorelai@dragonfly.example"),
            MentionCandidate(displayName: "Sookie St. James", email: "sookie@dragonfly.example"),
            MentionCandidate(displayName: "Michel Gerard", email: "michel@dragonfly.example"),
        ]
        .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
    }
}

private final class PlaygroundTextBlocks: TextBlockProvider {
    func textBlocks(matching query: String) async -> [EditorTextBlock] {
        [
            EditorTextBlock(title: "Greeting", html: "<p>Hi,</p><p></p>"),
            EditorTextBlock(title: "Signature", html: "<p>Kind regards,<br>Lorelai</p>"),
        ]
        .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
}

private final class PlaygroundSmartPicker: SmartPickerProvider {
    func smartPickerLinks(matching query: String) async -> [SmartPickerLink] {
        guard let url = URL(string: "https://nextcloud.local/f/42") else { return [] }
        return [SmartPickerLink(title: query.isEmpty ? "Shared file" : query, url: url)]
    }
}

#Preview {
    EditorPlayground()
}
#endif
