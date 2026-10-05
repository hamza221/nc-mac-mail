// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailStore
import NCMailSync
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// The compose window's content (§6.3–§6.9): From, To/Cc/Bcc, Subject, the editor, the
/// signature and quote under it, the attachments strip, and the toolbar's Send, attach and
/// "…" menus. Everything it shows comes from ``ComposerModel``, which writes the draft row.
struct ComposerView: View {
    @Bindable var model: ComposerModel

    @Environment(AppSession.self) private var session
    @Environment(\.ncTheme) private var theme
    @State private var picker: Picker?
    @State private var showsCustomSendLater = false
    @State private var showsTextBlocks = false
    @State private var showsSmartPicker = false
    @State private var showsFileImporter = false
    @State private var showsDiscardConfirmation = false
    @State private var filesError: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, subject }

    private enum Picker: Identifiable {
        case attach
        case shareLink
        case image
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                banners
                ComposerEditor(
                    document: model.document,
                    providers: EditorProviders(
                        mentions: model.suggestions, textBlocks: model.textBlocks, smartPicker: model.smartPicker),
                    onFileDrop: { model.attach($0) },
                    onMention: { model.mentioned($0) }
                )
                .frame(minHeight: 200)
                trailingBlocks
                if !model.attachments.isEmpty {
                    Divider()
                    AttachmentStrip(model: model)
                }
                Divider()
                statusBar
            }
        }
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            if case .success(let urls) = result { model.attach(fileURLs: urls) }
        }
        .sheet(item: $picker) { kind in filesPicker(kind) }
        .sheet(isPresented: $showsCustomSendLater) { CustomSendLaterSheet(model: model) }
        .sheet(isPresented: $showsTextBlocks) { TextBlocksSheet(model: model) }
        .sheet(isPresented: $showsSmartPicker) { SmartPickerSheet(model: model) }
        .alert(
            model.pendingWarnings.first?.message ?? "",
            isPresented: Binding(
                get: { !model.pendingWarnings.isEmpty }, set: { if !$0 { model.pendingWarnings = [] } })
        ) {
            Button("Send anyway") { model.confirmSend() }
            Button("Go back", role: .cancel) { model.pendingWarnings = [] }
        } message: {
            if model.pendingWarnings.count > 1 {
                Text(model.pendingWarnings.dropFirst().map(\.message).joined(separator: "\n"))
            }
        }
        .alert("Error", isPresented: Binding(get: { filesError != nil }, set: { if !$0 { filesError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(filesError ?? "")
        }
        .confirmationDialog("Discard this message?", isPresented: $showsDiscardConfirmation) {
            Button("Discard & close draft", role: .destructive) { model.discard() }
            Button("Keep editing", role: .cancel) {}
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .editing else { return }
            focus = model.focusesBody ? nil : .to
            if model.focusesBody { model.document.textView?.window?.makeFirstResponder(model.document.textView) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.tight) {
            fromRow
            RecipientField(
                label: String(localized: "To"),
                addresses: model.to,
                provider: model.suggestions,
                isInternal: model.isInternal,
                onAdd: { model.add($0, to: \.to) },
                onRemove: { model.remove($0, from: \.to) },
                trailing: AnyView(
                    Button(model.showsCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") { model.showsCcBcc.toggle() }
                        .buttonStyle(.borderless)
                )
            )
            .focused($focus, equals: .to)
            if model.warnings.contains(.emptyTo) { inlineWarning(.emptyTo) }
            if model.showsCcBcc || !model.cc.isEmpty || !model.bcc.isEmpty {
                RecipientField(
                    label: String(localized: "Cc"), addresses: model.cc, provider: model.suggestions,
                    isInternal: model.isInternal,
                    onAdd: { model.add($0, to: \.cc) }, onRemove: { model.remove($0, from: \.cc) })
                RecipientField(
                    label: String(localized: "Bcc"), addresses: model.bcc, provider: model.suggestions,
                    isInternal: model.isInternal,
                    onAdd: { model.add($0, to: \.bcc) }, onRemove: { model.remove($0, from: \.bcc) })
            }
            if model.warnings.contains(.noReply) { inlineWarning(.noReply) }
            HStack(spacing: theme.metrics.spacing.standard) {
                Text("Subject")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                TextField("Subject …", text: $model.subject)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
            }
        }
        .padding(theme.metrics.spacing.standard)
    }

    private var fromRow: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            Text("From")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Menu {
                ForEach(model.identities) { identity in
                    Button(identity.formatted) { model.select(identity) }
                }
            } label: {
                Text(verbatim: model.identity?.formatted ?? "")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private func inlineWarning(_ warning: ComposerWarning) -> some View {
        Text(warning.message)
            .font(.caption)
            .foregroundStyle(theme.colors.warning.element)
            .padding(.leading, theme.metrics.spacing.loose * 3)
    }

    @ViewBuilder
    private var banners: some View {
        if let message = model.failure ?? model.sendError ?? model.notice {
            HStack(spacing: theme.metrics.spacing.standard) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(
                        model.failure != nil || model.sendError != nil
                            ? AnyShapeStyle(theme.colors.error.element) : AnyShapeStyle(.primary))
                Spacer()
                Button("Dismiss") {
                    model.notice = nil
                    model.failure = nil
                }
                .buttonStyle(.borderless)
            }
            .padding(theme.metrics.spacing.standard)
            .background(theme.colors.primarySurface)
        }
    }

    /// The signature and quote, read-only, in the account's order (§6.6).
    @ViewBuilder
    private var trailingBlocks: some View {
        let signatureView = model.signature.map {
            SignaturePreview(signature: $0, isRich: model.document.mode == .rich)
        }
        if model.signatureAboveQuote || (model.quoteHTML == nil && model.quotePlain == nil) {
            signatureView
        }
        if model.quoteHTML != nil || model.quotePlain != nil {
            QuotePreview(model: model)
        }
        if !model.signatureAboveQuote, model.quoteHTML != nil || model.quotePlain != nil {
            signatureView
        }
    }

    private var statusBar: some View {
        HStack(spacing: theme.metrics.spacing.standard) {
            switch model.saveStatus {
            case .idle: EmptyView()
            case .saving: Text(model.kind == .outbox ? "Saving message …" : "Saving draft …")
            case .saved: Text(model.kind == .outbox ? "Message saved" : "Draft saved")
            case .failed(let reason):
                Text("Error saving draft").foregroundStyle(theme.colors.error.element).help(reason)
                Button("Save draft") { model.saveNow() }.buttonStyle(.borderless)
            }
            Spacer()
            if let sendAt = model.sendAt {
                Text("Send later \(sendAt.formatted(date: .abbreviated, time: .shortened))")
                Button("Clear") { model.sendAt = nil }.buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, theme.metrics.spacing.standard)
        .padding(.vertical, theme.metrics.spacing.tight)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Upload attachment") { showsFileImporter = true }
                Button("Add attachment from Files") { picker = .attach }
                Button("Add share link from Files") { picker = .shareLink }
            } label: {
                MailSymbol.attachment.view(label: .text("Add attachment"))
            }
            .help("Add attachment")
        }
        ToolbarItem(placement: .primaryAction) { moreMenu }
        ToolbarItem(placement: .primaryAction) { sendButton }
    }

    private var sendButton: some View {
        Menu {
            Button("Send now") {
                model.sendAt = nil
                model.requestSend()
            }
            ForEach(SendLaterPreset.allCases, id: \.self) { preset in
                let date = preset.date(from: Date())
                Button("\(preset.title) — \(date.formatted(date: .abbreviated, time: .shortened))") {
                    model.requestSend(at: date)
                }
            }
            Button("Custom date and time …") { showsCustomSendLater = true }
        } label: {
            Text(sendTitle)
        } primaryAction: {
            model.requestSend()
        }
        .disabled(!model.canSend)
        .help(model.canSend ? "" : String(localized: "Add a recipient to send"))
    }

    private var sendTitle: String {
        guard let sendAt = model.sendAt else { return String(localized: "Send") }
        return String(localized: "Send later \(sendAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var moreMenu: some View {
        Menu {
            Button("Smart picker") { showsSmartPicker = true }
            Button("Text blocks") { showsTextBlocks = true }
            if model.document.mode == .rich {
                Button("Insert image from Files") { picker = .image }
            }
            Divider()
            Toggle("Request a read receipt", isOn: $model.requestMdn)
            Toggle("Mark as AI generated", isOn: $model.isAiGenerated)
            Divider()
            Toggle("Sign message with S/MIME", isOn: $model.smimeSign)
                .disabled(model.smimeCertificate?.canSign != true)
            Toggle("Encrypt message with S/MIME", isOn: $model.smimeEncrypt)
                .disabled(model.smimeCertificate?.canEncrypt != true)
            Divider()
            Button("Save draft") { model.saveNow() }
            Button("Discard & close draft", role: .destructive) { showsDiscardConfirmation = true }
        } label: {
            Text("…")
        }
        .help("More actions")
    }

    // MARK: - Files

    @ViewBuilder
    private func filesPicker(_ kind: Picker) -> some View {
        if let accountId = model.accountId {
            FilesPicker(accountId: accountId, mode: mode(for: kind)) { choice in
                guard case .files(let entries) = choice else { return }
                Task { await chose(entries, kind: kind, accountId: accountId) }
            }
        }
    }

    private func mode(for kind: Picker) -> FilesPicker.Mode {
        switch kind {
        case .attach: .files(multiple: true)
        case .shareLink: .files(multiple: false)
        case .image: .files(filter: .images, multiple: false)
        }
    }

    private func chose(_ entries: [FilesEntry], kind: Picker, accountId: Int64) async {
        switch kind {
        case .attach:
            guard let draftId = await model.ensureDraft() else { return }
            do {
                try await FilesActions.attach(entries, draftId: draftId, store: session.store)
                model.filesAttached()
            } catch {
                filesError = String(localized: "Could not add the attachment.")
            }
        case .shareLink:
            if let error = await FilesActions.insertShareLinks(
                Array(entries.prefix(1)), accountId: accountId, into: model.document, session: session)
            {
                filesError = error.message
            }
        case .image:
            guard let entry = entries.first else { return }
            if let error = await FilesActions.insertImage(
                entry, accountId: accountId, into: model.document, session: session)
            {
                filesError = error.message
            }
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.attach(fileURLs: [url]) }
            }
        }
    }
}

/// The signature as it will be sent, read-only (it changes with From, §6.4).
private struct SignaturePreview: View {
    let signature: String
    let isRich: Bool
    @Environment(\.ncTheme) private var theme

    var body: some View {
        Text(
            SignatureText.plain(
                SignatureText.isHTML(signature) ? ComposerModel.plainText(fromHTML: signature) : signature)
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.metrics.spacing.loose)
        .padding(.vertical, theme.metrics.spacing.tight)
        .textSelection(.enabled)
        .accessibilityLabel(Text("Signature"))
    }
}
