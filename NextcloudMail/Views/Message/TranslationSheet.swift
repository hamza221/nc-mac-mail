// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudUI
import SwiftUI

/// The translation modal (§5.8). From and To pickers, then the source and the translation
/// side by side; the translation is a `translation` row (ADR-0067), pending until it lands.
///
/// The language list is built from `Locale`, not from the server: the server's
/// `translation/languages` is not mirrored, and on the test server it is empty. A pair the
/// provider cannot do comes back as a failed row and says so.
struct TranslationSheet: View {
    let model: MessageViewModel

    @Environment(\.ncTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// Nil is "Detect language".
    @State private var from: String?
    @State private var to: String = TranslationLanguages.readerDefault()
    @State private var copied: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Translate message").font(.title3.weight(theme.typography.heading))
            HStack(spacing: theme.metrics.spacing.standard) {
                Picker("From", selection: $from) {
                    Text("Detect language").tag(String?.none)
                    ForEach(TranslationLanguages.all, id: \.code) { language in
                        Text(language.name).tag(String?.some(language.code))
                    }
                }
                Picker("To", selection: $to) {
                    ForEach(TranslationLanguages.all, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Button("Translate") {
                    copied = nil
                    model.requestTranslation(to: to, from: from)
                }
                .buttonStyle(.primary)
                .disabled(model.bodyText == nil || model.translation == .pending)
            }
            // Changing a language clears the result, as the web's modal does.
            .onChange(of: from) { model.clearTranslation() }
            .onChange(of: to) { model.clearTranslation() }

            if model.bodyText == nil {
                Text("Please wait for the message to load").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: theme.metrics.spacing.loose) {
                    column(title: "Original", text: model.bodyText ?? "")
                    translationColumn
                }
            }

            Text("This translation is generated using AI and may contain inaccuracies")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let copied {
                    Text(copied ? "Translation copied to clipboard" : "Translation could not be copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let text = model.translation.value {
                    Button("Copy translated text") { copy(text) }
                        .buttonStyle(.secondary)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.tertiary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: TranslationSheetSize.width, minHeight: TranslationSheetSize.height)
        .onDisappear { model.clearTranslation() }
    }

    @ViewBuilder
    private var translationColumn: some View {
        switch model.translation {
        case .idle:
            column(title: "Translation", text: "")
        case .pending:
            VStack(alignment: .leading) {
                Text("Translation").font(.headline)
                ProgressView("Translating")
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .ready(let text):
            column(title: "Translation", text: text)
        case .empty, .failed:
            VStack(alignment: .leading) {
                Text("Translation").font(.headline)
                Text("The message could not be translated").foregroundStyle(theme.colors.error.element)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func column(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            Text(title).font(.headline)
            ScrollView {
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Every language `Locale` can name, by ISO code, sorted by the reader's name for it.
enum TranslationLanguages {
    struct Language: Equatable {
        var code: String
        var name: String
    }

    static let all: [Language] = {
        let codes = Set(
            Locale.availableIdentifiers.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        return codes.compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { Language(code: code, name: $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// The reader's language, matched on its code alone so `pt-BR` and `pt_BR` both land on
    /// Portuguese, as the web's matching does.
    static func readerDefault(_ locale: Locale = .current) -> String {
        let code = locale.language.languageCode?.identifier ?? "en"
        return all.contains { $0.code == code } ? code : "en"
    }
}

/// The modal's opening size: a window shape, not a theme token.
private enum TranslationSheetSize {
    static let width = 720.0
    static let height = 460.0
}
