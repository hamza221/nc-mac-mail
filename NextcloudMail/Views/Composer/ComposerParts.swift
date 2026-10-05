// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NextcloudUI
import SwiftUI

// MARK: - Quote

/// The original being answered, read-only under the editor (ADR-0065): the server's
/// sanitised HTML through the message web view and its rewriter — so the quote is drawn
/// with exactly the protections a message gets — or the "> " text in plain mode.
struct QuotePreview: View {
    let model: ComposerModel

    @Environment(\.ncTheme) private var theme
    @State private var expanded = true
    @State private var rendered: RenderedMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            HStack {
                Button(expanded ? "Hide quoted text" : "Show quoted text") { expanded.toggle() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Edit quoted text") { model.editQuotedText() }
                    .buttonStyle(.borderless)
                    .help("Moves the quoted text into the editor. Formatting the editor cannot represent is lost.")
            }
            if expanded { content }
        }
        .padding(.horizontal, theme.metrics.spacing.standard)
        .padding(.vertical, theme.metrics.spacing.tight)
        .task(id: model.quoteHTML) { await render() }
    }

    @ViewBuilder
    private var content: some View {
        if model.document.mode == .rich, let rendered, let services = services {
            MessageBodyWebView(
                rendered: rendered,
                assetContext: .none,
                store: services.store,
                client: services.client,
                server: services.server,
                onLinkActivated: { _ in },
                onBlocked: { _ in }
            )
            .frame(minHeight: 120, idealHeight: 220, maxHeight: 320)
        } else if let plain = model.quotePlain {
            ScrollView {
                Text(verbatim: plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 80, idealHeight: 160, maxHeight: 240)
        }
    }

    private var services: MessageViewServices? {
        model.session.messageServices(model.accountId)
    }

    /// Remote images stay blocked in the quote: the composer is no place to decide to load
    /// a tracker.
    private func render() async {
        guard let html = model.quoteHTML, let server = services?.server else {
            rendered = nil
            return
        }
        let policy = MessageRenderPolicy(server: server, messageRemoteId: 0, showsRemoteImages: false)
        let fontSize = MessageDocument.preferredBaseFontSize
        rendered = await Task.detached(priority: .userInitiated) {
            MessageHTMLRewriter(policy: policy).render(fragment: html, baseFontSize: fontSize)
        }.value
    }
}

// MARK: - Attachments

/// The attachments strip (§6.7): one chip per `draftAttachment` row — name, size or
/// "uploads when sent", a cloud badge for Files, an envelope for a forwarded message —
/// and a collapsible "{count} attachments (total size)" header once it wraps.
struct AttachmentStrip: View {
    let model: ComposerModel

    @Environment(\.ncTheme) private var theme
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            if model.attachments.count > 3 {
                Button {
                    collapsed.toggle()
                } label: {
                    Text(summary).font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if !collapsed {
                FlowLayout(spacing: theme.metrics.spacing.tight) {
                    ForEach(model.attachments) { item in
                        NCChip(label(for: item), onRemove: { model.removeAttachment(item) }) {
                            symbol(for: item).view(size: .small, label: .decorative)
                        }
                        .help(item.fileName)
                    }
                }
            }
        }
        .padding(theme.metrics.spacing.standard)
    }

    private var summary: String {
        let total = model.attachments.compactMap(\.size).reduce(0, +)
        return String(
            localized:
                "\(model.attachments.count) attachments (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))"
        )
    }

    private func label(for item: ComposerModel.AttachmentItem) -> String {
        guard let size = item.size else { return item.fileName }
        return "\(item.fileName) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func symbol(for item: ComposerModel.AttachmentItem) -> MailSymbol {
        if item.isCloud { return .cloudFile }
        if item.isMessage { return .forwardedMessage }
        return .attachment
    }
}

// MARK: - Send later

/// "Custom date": now + 1 h by default, five-minute steps, nothing before today (§6.8).
struct CustomSendLaterSheet: View {
    let model: ComposerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var date = SendLaterPreset.customDefault(from: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.loose) {
            Text("Send later").font(.headline)
            DatePicker(
                "Send at", selection: $date, in: Calendar.current.startOfDay(for: Date())...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send later") {
                    model.requestSend(at: roundedToFiveMinutes(date))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(date <= Date())
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: 360)
    }

    private func roundedToFiveMinutes(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 300).rounded(.up) * 300)
    }
}

// MARK: - Text blocks

/// "… ▸ Text blocks" (§6.8): own and shared blocks, select → Insert.
struct TextBlocksSheet: View {
    let model: ComposerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var blocks: [TextBlockRecord] = []
    @State private var selection: Int64?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Text blocks").font(.headline)
            if loaded && blocks.isEmpty {
                Text("No text blocks available. Create them in Mail settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(blocks, id: \.id, selection: $selection) { block in
                    VStack(alignment: .leading) {
                        Text(verbatim: block.title)
                        Text(verbatim: ComposerModel.plainText(fromHTML: block.content))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if block.isShared, let owner = block.ownerId {
                            Text("Shared by \(owner)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(block.id)
                }
                .frame(minHeight: 200)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Insert") {
                    if let block = blocks.first(where: { $0.id == selection }) {
                        model.insert(textBlock: EditorTextBlock(title: block.title, html: block.content))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: 420, minHeight: 320)
        .task {
            blocks = await model.textBlocks?.allBlocks() ?? []
            loaded = true
        }
    }
}

// MARK: - Smart picker

/// "… ▸ Smart picker": search every provider, pick a result, its link goes in at the caret.
/// The search is the server-result engine's; this sheet re-reads the rows it writes.
struct SmartPickerSheet: View {
    let model: ComposerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ncTheme) private var theme
    @State private var term = ""
    @State private var links: [SmartPickerLink] = []
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.standard) {
            Text("Smart picker").font(.headline)
            TextField("Search", text: $term)
                .textFieldStyle(.roundedBorder)
            List(links, id: \.url, selection: $selection) { link in
                VStack(alignment: .leading) {
                    Text(verbatim: link.title)
                    Text(verbatim: link.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
                .tag(link.url)
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Insert") {
                    if let link = links.first(where: { $0.url == selection }) { model.insert(link: link) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(minWidth: 460, minHeight: 360)
        .task(id: term) { await search() }
    }

    /// Asks once, then re-reads while the provider searches land (they arrive one row per
    /// provider over a second or two).
    private func search() async {
        guard let provider = model.smartPicker else { return }
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            links = []
            return
        }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        links = await provider.smartPickerLinks(matching: trimmed)
        for _ in 0..<10 {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            links = await provider.storedLinks(term: trimmed)
        }
    }
}
