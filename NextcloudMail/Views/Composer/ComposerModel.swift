// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailStore
import NCMailSync
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// One composer window's state: the fields, the editor document, and the local `draft` row
/// they are written to (ADR-0066). Every edit lands in the row within a fraction of a
/// second and the drafts engine is told; the engine, not this model, talks to the server.
@MainActor
@Observable
final class ComposerModel {
    /// One entry of the From menu: the account itself or one of its aliases.
    struct Identity: Identifiable, Hashable {
        var accountId: Int64
        var aliasId: Int64?
        var name: String
        var email: String
        var signature: String?
        var smimeCertificateRemoteId: Int64?

        var id: String { "\(accountId)-\(aliasId.map(String.init) ?? "account")" }
        var formatted: String { name.isEmpty ? email : "\(name) <\(email)>" }
    }

    /// One chip of the attachments strip.
    struct AttachmentItem: Identifiable, Equatable {
        var id: Int64
        var kind: String
        var fileName: String
        var mime: String?
        var size: Int64?
        var isUploaded: Bool
        var isCloud: Bool { kind == "cloud" }
        var isMessage: Bool { kind == "message" }
    }

    enum Phase: Equatable {
        case loading
        case editing
        /// Handed to the drafts engine for sending; the window is hidden until the row
        /// says sent (close), undone (show) or failed (show with the error).
        case sending
        case finished
    }

    enum SaveStatus: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    let request: ComposeRequest
    let document: EditorDocument
    private(set) var phase: Phase = .loading
    private(set) var kind: ComposeSeed.Kind = .new

    var to: [ComposerAddress] = [] { didSet { fieldsChanged() } }
    var cc: [ComposerAddress] = [] { didSet { fieldsChanged() } }
    var bcc: [ComposerAddress] = [] { didSet { fieldsChanged() } }
    var subject = "" { didSet { fieldsChanged() } }
    var showsCcBcc = false
    private(set) var identities: [Identity] = []
    private(set) var identity: Identity?
    private(set) var accountId: Int64?
    private(set) var attachments: [AttachmentItem] = []

    /// The read-only original under the editor (ADR-0065).
    private(set) var quoteHTML: String?
    private(set) var quotePlain: String?
    /// The signature, kept outside the editor so changing From can replace it (§6.4).
    private(set) var signature: String?
    private(set) var signatureAboveQuote = true
    /// Settings "Reply position": the user writes below the quote.
    private(set) var replyBelowQuote = false
    private(set) var replyingTo: [ComposerAddress] = []

    var sendAt: Date? { didSet { fieldsChanged() } }
    var requestMdn = false { didSet { fieldsChanged() } }
    var isAiGenerated = false { didSet { fieldsChanged() } }
    var smimeSign = false { didSet { fieldsChanged() } }
    var smimeEncrypt = false { didSet { fieldsChanged() } }
    private(set) var smimeCertificates: [SmimeCertificateRecord] = []

    private(set) var saveStatus: SaveStatus = .idle
    private(set) var sendError: String?
    /// The pre-send warnings waiting for "Send anyway" (§6.3), and the send they hold.
    var pendingWarnings: [ComposerWarning] = []
    @ObservationIgnored private var pendingSendAt: Date?
    /// One-off information: "Attachments were not copied…", "Message saved".
    var notice: String?
    var failure: String?
    private(set) var focusesBody = false

    private(set) var draftId: Int64?
    private(set) var hasChanges = false

    @ObservationIgnored let session: ComposerServices
    @ObservationIgnored private(set) var textBlocks: StoreTextBlockProvider?
    @ObservationIgnored private(set) var smartPicker: StoreSmartPickerProvider?
    @ObservationIgnored private(set) var suggestions: RecipientSuggestionProvider?
    @ObservationIgnored private var loginId: Int64?
    @ObservationIgnored private var inReplyToMessageId: String?
    @ObservationIgnored private var replacesMessageId: Int64?
    @ObservationIgnored private var replacesOutboxId: Int64?
    @ObservationIgnored private var outboxCancelled = false
    @ObservationIgnored private var seedAttachments: [ComposeSeed.Attachment] = []
    @ObservationIgnored private var isApplyingSeed = false
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var rowObservation: Task<Void, Never>?
    @ObservationIgnored private var editObserver: (any NSObjectProtocol)?
    @ObservationIgnored weak var window: NSWindow?
    /// Called with the local draft id once a row exists, for scene restoration.
    @ObservationIgnored var onDraftCreated: ((Int64) -> Void)?
    /// Closes the window for good (the scene's `dismissWindow`).
    @ObservationIgnored var dismiss: (() -> Void)?

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "composer")
    /// Local writes coalesce for this long; the server hears 5 s after the last one.
    private static let localWriteDelay: Duration = .milliseconds(400)

    init(request: ComposeRequest, session: ComposerServices) {
        self.request = request
        self.session = session
        document = EditorDocument(mode: .rich)
    }

    var isFinished: Bool { phase == .finished }

    /// Content the user would lose track of if the app quit now.
    var hasUnsavedChanges: Bool { hasChanges && phase == .editing && draftId != nil }

    var title: String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return kindTitle
    }

    var kindTitle: String {
        switch kind {
        case .new: String(localized: "New message")
        case .reply: String(localized: "Reply")
        case .forward: String(localized: "Forward")
        case .draft: String(localized: "Draft")
        case .outbox: String(localized: "Edit message")
        }
    }

    var hasRecipients: Bool { !(to.isEmpty && cc.isEmpty && bcc.isEmpty) }

    /// Send is disabled with no recipients, or while a send is under way (§6.9).
    var canSend: Bool { phase == .editing && hasRecipients && accountId != nil }

    var warnings: Set<ComposerWarning> {
        ComposerWarning.evaluate(
            ComposerWarning.Input(
                subject: subject, to: to, cc: cc, bcc: bcc, bodyText: document.plainText(),
                attachmentCount: attachments.count, replyingTo: replyingTo))
    }

    /// The certificate for the selected identity, which S/MIME needs (§6.8).
    var smimeCertificate: SmimeCertificateRecord? {
        guard let remoteId = identity?.smimeCertificateRemoteId else { return nil }
        return smimeCertificates.first { $0.remoteId == remoteId }
    }

    // MARK: - Loading

    /// Builds the window's content: resumes the local row a restored window names, or
    /// routes the request.
    func load(restoringDraftId: Int64?) async {
        guard phase == .loading else { return }
        ComposerWindows.shared.register(self)
        let store = session.store
        if let restoringDraftId, let row = try? await store.draft(id: restoringDraftId) {
            await resume(row)
            return
        }
        let seed = await ComposeSeedBuilder.seed(
            for: request, store: store, preferredAccountId: await currentAccountId(),
            waitForBody: { [session] messageId in await Self.waitForBody(messageId, session: session) })
        await apply(seed)
    }

    /// How long a reply or forward waits for a body the mirror does not have yet before it
    /// quotes the preview instead (`ComposerLiveTests` records how long a just-arrived
    /// message's body actually takes).
    static let bodyWait: Duration = .seconds(20)

    private static func waitForBody(_ messageId: Int64, session: ComposerServices) async -> StoredBody? {
        guard let message = try? await session.store.message(id: messageId),
            let running = session.engine.account(id: message.accountId)
        else { return nil }
        await running.prioritiser.prioritise(messageId: messageId)
        let store = session.store
        return await withTaskGroup(of: StoredBody?.self) { group in
            group.addTask {
                do {
                    for try await body in store.observeBody(messageId: messageId) where body != nil {
                        return body
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: bodyWait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func apply(_ seed: ComposeSeed) async {
        isApplyingSeed = true
        defer { isApplyingSeed = false }
        kind = seed.kind
        failure = seed.failure
        notice = seed.notice
        focusesBody = seed.focusesBody
        to = seed.to
        cc = seed.cc
        bcc = seed.bcc
        showsCcBcc = !seed.cc.isEmpty || !seed.bcc.isEmpty
        subject = seed.subject
        quoteHTML = seed.quoteHTML
        quotePlain = seed.quotePlain
        replyingTo = seed.replyingTo
        sendAt = seed.sendAt
        requestMdn = seed.requestMdn
        isAiGenerated = seed.isAiGenerated
        smimeSign = seed.smimeSign
        smimeEncrypt = seed.smimeEncrypt
        inReplyToMessageId = seed.inReplyToMessageId
        replacesMessageId = seed.replacesMessageId
        replacesOutboxId = seed.replacesOutboxId
        seedAttachments = seed.attachments

        await loadAccount(seed.accountId, aliasId: seed.aliasId)
        var account: AccountRecord?
        if let accountId { account = try? await session.store.account(id: accountId) }
        signatureAboveQuote = account?.signatureAboveQuote ?? true
        if seed.insertsSignature {
            signature = identity?.signature?.isEmpty == false ? identity?.signature : nil
        }
        await loadReplyPosition()

        // Writing mode: the account's, forced rich by an image signature or HTML content (§6.5).
        let wantsRich =
            account?.editorMode != "plaintext" || seed.bodyIsHTML || (signature.map(SignatureText.hasImage) ?? false)
        if !wantsRich { document.disableFormatting() }
        if seed.bodyIsHTML {
            document.setHTML(seed.body)
        } else if !seed.body.isEmpty {
            if document.mode == .rich {
                document.setHTML(QuoteBlock.escape(seed.body).replacingOccurrences(of: "\n", with: "<br>"))
            } else {
                document.setPlainText(seed.body)
            }
        }
        phase = .editing
        observeEdits()

        // Content that arrived with the request — a reply's quote copy, forwarded parts,
        // a mailto body, an outbox entry — is something to save; a blank composer is not
        // a draft until the user changes it (§6.1).
        let hasContent =
            !seed.attachments.isEmpty || !seed.body.isEmpty || seed.kind == .outbox || seed.kind == .draft
        if hasContent {
            hasChanges = true
            await ensureDraft()
        }
    }

    private func resume(_ row: DraftRecord) async {
        isApplyingSeed = true
        defer { isApplyingSeed = false }
        draftId = row.id
        kind = .draft
        subject = row.subject ?? ""
        let recipients = (try? await session.store.recipients(draftId: row.id ?? 0)) ?? []
        func list(_ kind: String) -> [ComposerAddress] {
            recipients.filter { $0.kind == kind }.sorted { $0.position < $1.position }
                .map { ComposerAddress(email: $0.email, label: $0.label) }
        }
        to = list("to")
        cc = list("cc")
        bcc = list("bcc")
        showsCcBcc = !cc.isEmpty || !bcc.isEmpty
        sendAt = row.sendAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        requestMdn = row.requestMdn
        isAiGenerated = row.isAiGenerated
        smimeSign = row.smimeSign
        smimeEncrypt = row.smimeEncrypt
        inReplyToMessageId = row.inReplyToMessageId
        replacesMessageId = row.replacesMessageId
        await loadAccount(row.accountId, aliasId: row.aliasId)
        if row.isHtml {
            document.setHTML(row.editorBody ?? row.bodyHtml ?? "")
        } else {
            document.disableFormatting()
            document.setPlainText(row.bodyPlain ?? "")
        }
        // The body as saved already holds the signature and quote; nothing is added again.
        signature = nil
        quoteHTML = nil
        quotePlain = nil
        hasChanges = true
        phase = .editing
        observeEdits()
        await reloadAttachments()
        observeRow()
        if let state = row.sendState.flatMap(DraftSendState.init(rawValue:)), state != .failed, state != .closing {
            phase = .sending
            hide()
        }
    }

    private func loadAccount(_ accountId: Int64?, aliasId: Int64?) async {
        let store = session.store
        var all: [Identity] = []
        for account in (try? await store.accounts()) ?? [] {
            all.append(
                Identity(
                    accountId: account.id, aliasId: nil, name: account.name, email: account.emailAddress,
                    signature: account.signature, smimeCertificateRemoteId: account.smimeCertificateRemoteId))
            for alias in (try? await store.aliases(accountId: account.id)) ?? [] {
                all.append(
                    Identity(
                        accountId: account.id, aliasId: alias.id, name: alias.name ?? account.name,
                        email: alias.email, signature: alias.signature,
                        smimeCertificateRemoteId: alias.smimeCertificateRemoteId))
            }
        }
        identities = all
        identity =
            all.first { $0.accountId == accountId && $0.aliasId == aliasId && aliasId != nil }
            ?? all.first { $0.accountId == accountId && $0.aliasId == nil }
            ?? all.first
        self.accountId = identity?.accountId
        await loadLoginScoped()
    }

    private func loadLoginScoped() async {
        guard let accountId, let account = try? await session.store.account(id: accountId),
            let login = try? await session.store.login(for: account.identity), let loginId = login.id
        else { return }
        self.loginId = loginId
        textBlocks = StoreTextBlockProvider(store: session.store, loginId: loginId)
        let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
        smartPicker = StoreSmartPickerProvider(store: session.store, loginId: loginId) { [session] term in
            guard let fetcher = session.engine.serverResults(sessionId: sessionId) else { return }
            Task { await fetcher.requestSmartPicker(term: term) }
        }
        internalAddresses = (try? await session.store.internalAddresses(loginId: loginId)) ?? []
        smimeCertificates = (try? await session.store.smimeCertificates(loginId: loginId)) ?? []
        let engine = session.engine
        let provider = RecipientSuggestionProvider(
            store: session.store, loginId: loginId, fetcher: { engine.serverResults(sessionId: sessionId) })
        suggestions = provider
        await provider.prepare()
    }

    /// The `internal-addresses` list; empty means the feature is off and nothing is red.
    private(set) var internalAddresses: [InternalAddressRecord] = []

    /// Nil when there is no internal list; otherwise whether an address is inside it, by
    /// exact address or by domain (§6.4).
    var isInternal: ((ComposerAddress) -> Bool)? {
        guard !internalAddresses.isEmpty else { return nil }
        let individuals = Set(internalAddresses.filter { $0.type != "domain" }.map { $0.address.lowercased() })
        let domains = Set(internalAddresses.filter { $0.type == "domain" }.map { $0.address.lowercased() })
        return { address in
            let email = address.key
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            return individuals.contains(email) || domains.contains(domain)
        }
    }

    private func loadReplyPosition() async {
        guard let loginId else { return }
        let value = try? await session.store.preferenceValue(key: "reply-mode", loginId: loginId)
        replyBelowQuote = value == "bottom"
    }

    // MARK: - From

    /// Changing From replaces the signature and resets S/MIME when the new identity has no
    /// certificate (§6.4).
    func select(_ newIdentity: Identity) {
        guard newIdentity != identity else { return }
        let changedAccount = newIdentity.accountId != identity?.accountId
        identity = newIdentity
        accountId = newIdentity.accountId
        if kind != .draft || signature != nil {
            signature = newIdentity.signature?.isEmpty == false ? newIdentity.signature : nil
            if let signature, SignatureText.hasImage(signature), document.mode == .plain {
                document.enableFormatting()
            }
        }
        if smimeCertificate == nil, smimeSign || smimeEncrypt {
            smimeSign = false
            smimeEncrypt = false
            notice = String(localized: "S/MIME was turned off: the selected identity has no certificate.")
        }
        if changedAccount {
            Task {
                await loadLoginScoped()
                await moveDraftToAccount()
            }
        }
        fieldsChanged()
    }

    /// A draft row belongs to one account's engine; changing account starts a new row on
    /// the new one and discards the old.
    private func moveDraftToAccount() async {
        guard let oldId = draftId, let row = try? await session.store.draft(id: oldId),
            let accountId, row.accountId != accountId
        else { return }
        draftId = nil
        await ensureDraft()
        if let outbox = session.engine.outbox(accountId: row.accountId) { await outbox.discardDraft(oldId) }
    }

    // MARK: - Editing

    private func observeEdits() {
        guard editObserver == nil else { return }
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: document.storage, queue: .main
        ) { [weak self] _ in
            // Characters and attributes both: making a word bold is an edit worth saving.
            MainActor.assumeIsolated { self?.bodyChanged() }
        }
    }

    private func bodyChanged() {
        guard phase == .editing, !isApplyingSeed else { return }
        markChanged()
    }

    private func fieldsChanged() {
        guard phase == .editing, !isApplyingSeed else { return }
        markChanged()
    }

    private func markChanged() {
        hasChanges = true
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.localWriteDelay)
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// ⌘S: write the row and flush to the server now rather than in 5 s.
    func saveNow() {
        Task {
            await writeNow()
            guard let draftId, let outbox = outbox else { return }
            await outbox.saveDraft(draftId)
        }
    }

    private var outbox: OutboxSender? {
        accountId.flatMap { session.engine.outbox(accountId: $0) }
    }

    /// Creates the row on the first change; afterwards rewrites it.
    @discardableResult
    func ensureDraft() async -> Int64? {
        if let draftId { return draftId }
        guard let accountId else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        let row = DraftRecord(accountId: accountId, createdAt: now, updatedAt: now)
        do {
            let inserted = try await session.store.insert(draft: row)
            guard let id = inserted.id else { return nil }
            draftId = id
            onDraftCreated?(id)
            for attachment in seedAttachments {
                _ = try await session.store.insert(
                    draftAttachment: DraftAttachmentRecord(
                        draftId: id, kind: attachment.kind, fileName: attachment.fileName, mime: attachment.mime,
                        size: attachment.size, localPath: attachment.localPath, payloadJSON: attachment.payloadJSON))
            }
            seedAttachments = []
            observeRow()
            await writeNow()
            await reloadAttachments()
            return id
        } catch {
            Self.logger.error("draft row not created: \(String(describing: error), privacy: .public)")
            saveStatus = .failed(String(localized: "Error saving draft"))
            return nil
        }
    }

    /// Writes every field to the row and tells the engine. Whole-row write: the engine's
    /// own writes are column-targeted and never touch these columns.
    func writeNow() async {
        writeTask?.cancel()
        guard phase == .editing, hasChanges else { return }
        guard let id = await ensureDraftForWrite() else { return }
        do {
            guard var row = try await session.store.draft(id: id) else { return }
            let body = composedBody()
            row.accountId = accountId ?? row.accountId
            row.aliasId = identity?.aliasId
            row.subject = subject
            row.isHtml = document.mode == .rich
            row.bodyHtml = body.html
            row.bodyPlain = body.plain
            row.editorBody = document.mode == .rich ? body.html : nil
            row.inReplyToMessageId = inReplyToMessageId
            row.replacesMessageId = replacesMessageId
            row.requestMdn = requestMdn
            row.isAiGenerated = isAiGenerated
            row.smimeSign = smimeSign
            row.smimeEncrypt = smimeEncrypt
            row.smimeCertificateRemoteId = smimeSign || smimeEncrypt ? smimeCertificate?.remoteId : nil
            row.sendAt = sendAt.map { Int64($0.timeIntervalSince1970.rounded(.down)) }
            row.updatedAt = max(Int64(Date().timeIntervalSince1970), row.updatedAt + 1)
            try await session.store.update(draft: row)
            try await session.store.replaceRecipients(recipientRows(draftId: id), draftId: id)
            await outbox?.saveDraft(id)
        } catch {
            Self.logger.error("draft row not written: \(String(describing: error), privacy: .public)")
            saveStatus = .failed(String(localized: "Error saving draft"))
        }
    }

    private func ensureDraftForWrite() async -> Int64? {
        if let draftId { return draftId }
        return await ensureDraft()
    }

    private func recipientRows(draftId: Int64) -> [DraftRecipientRecord] {
        var rows: [DraftRecipientRecord] = []
        for (kind, list) in [("to", to), ("cc", cc), ("bcc", bcc)] {
            for (position, address) in list.enumerated() {
                rows.append(
                    DraftRecipientRecord(
                        draftId: draftId, kind: kind, position: position, email: address.email, label: address.label))
            }
        }
        return rows
    }

    /// The message as sent: what the user wrote, the signature and the quote, in the
    /// account's order (§6.6). The editor's own HTML stays separate in `editorBody`.
    func composedBody() -> (html: String?, plain: String) {
        let plainSignature = signature.map { sig in
            SignatureText.plain(SignatureText.isHTML(sig) ? Self.plainText(fromHTML: sig) : sig)
        }
        let written = document.plainText()
        var plainParts: [String] = []
        if replyBelowQuote, let quotePlain { plainParts.append(quotePlain) }
        plainParts.append(written)
        if signatureAboveQuote || quotePlain == nil, let plainSignature { plainParts.append(plainSignature) }
        if !replyBelowQuote, let quotePlain { plainParts.append(quotePlain) }
        if !signatureAboveQuote, quotePlain != nil, let plainSignature { plainParts.append(plainSignature) }
        let plain = plainParts.joined(separator: "\n\n")
        guard document.mode == .rich else { return (nil, plain) }

        let htmlSignature = signature.map(SignatureText.html)
        var html = ""
        if replyBelowQuote, let quoteHTML { html += quoteHTML }
        html += document.html()
        if signatureAboveQuote || quoteHTML == nil, let htmlSignature {
            html += "<div class=\"signature\">\(htmlSignature)</div>"
        }
        if !replyBelowQuote, let quoteHTML { html += quoteHTML }
        if !signatureAboveQuote, quoteHTML != nil, let htmlSignature {
            html += "<div class=\"signature\">\(htmlSignature)</div>"
        }
        return (html, plain)
    }

    /// "Edit quoted text": the quote moves into the editor through `HTMLImporter`, accepting
    /// the loss of anything outside the editor's tag set (ADR-0065).
    func editQuotedText() {
        if document.mode == .rich, let quoteHTML {
            let current = document.html()
            document.setHTML(replyBelowQuote ? quoteHTML + current : current + quoteHTML)
        } else if let quotePlain {
            let current = document.plainText()
            document.setPlainText(replyBelowQuote ? quotePlain + "\n\n" + current : current + "\n\n" + quotePlain)
        }
        quoteHTML = nil
        quotePlain = nil
        markChanged()
    }

    // MARK: - Recipients

    /// Adds addresses to a field, ignoring case-insensitive duplicates already in it (§6.4).
    func add(_ addresses: [ComposerAddress], to field: ReferenceWritableKeyPath<ComposerModel, [ComposerAddress]>) {
        var current = self[keyPath: field]
        var seen = Set(current.map(\.key))
        for address in addresses where address.isValid && seen.insert(address.key).inserted {
            current.append(address)
        }
        self[keyPath: field] = current
    }

    func remove(_ address: ComposerAddress, from field: ReferenceWritableKeyPath<ComposerModel, [ComposerAddress]>) {
        self[keyPath: field].removeAll { $0.key == address.key }
    }

    /// `@` in the editor adds the person to To (§6.5).
    func mentioned(_ candidate: MentionCandidate) {
        add([ComposerAddress(email: candidate.email, label: candidate.displayName)], to: \.to)
    }

    // MARK: - Attachments

    func attach(fileURLs: [URL]) {
        Task {
            guard let draftId = await ensureDraft() else { return }
            for url in fileURLs {
                do {
                    let staged = try AttachmentStaging.stage(copying: url)
                    _ = try await session.store.insert(
                        draftAttachment: DraftAttachmentRecord(
                            draftId: draftId, kind: "local", fileName: url.lastPathComponent,
                            mime: Self.mime(for: url), size: AttachmentStaging.size(of: staged),
                            localPath: staged.path))
                } catch {
                    Self.logger.error("attachment not staged: \(String(describing: error), privacy: .public)")
                    notice = String(localized: "Could not attach the file.")
                }
            }
            await attachmentsChanged()
        }
    }

    /// Pasted or dropped onto the editor: an attachment, never inline content (§6.5).
    func attach(_ dropped: EditorDroppedFile) {
        switch dropped {
        case .url(let url):
            attach(fileURLs: [url])
        case .data(let data, let name):
            Task {
                guard let draftId = await ensureDraft() else { return }
                do {
                    let staged = try AttachmentStaging.stage(data: data, name: name)
                    _ = try await session.store.insert(
                        draftAttachment: DraftAttachmentRecord(
                            draftId: draftId, kind: "local", fileName: name, mime: Self.mime(for: staged),
                            size: Int64(data.count), localPath: staged.path))
                } catch {
                    notice = String(localized: "Could not attach the file.")
                }
                await attachmentsChanged()
            }
        }
    }

    /// Files rows were inserted by WS-33's `FilesActions.attach`; the strip re-reads them.
    func filesAttached() {
        Task { await attachmentsChanged() }
    }

    func removeAttachment(_ item: AttachmentItem) {
        Task {
            let rows = (try? await session.store.attachments(draftId: draftId ?? 0)) ?? []
            if let path = rows.first(where: { $0.id == item.id })?.localPath { AttachmentStaging.discard(path: path) }
            try? await session.store.deleteDraftAttachment(id: item.id)
            await attachmentsChanged()
        }
    }

    private func attachmentsChanged() async {
        hasChanges = true
        await reloadAttachments()
        await writeNow()
    }

    func reloadAttachments() async {
        guard let draftId else { return }
        let rows = (try? await session.store.attachments(draftId: draftId)) ?? []
        attachments = rows.compactMap { row in
            guard let id = row.id else { return nil }
            return AttachmentItem(
                id: id, kind: row.kind, fileName: row.fileName, mime: row.mime, size: row.size,
                isUploaded: row.kind != "local" || row.remoteAttachmentId != nil)
        }
    }

    static func mime(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    // MARK: - Inserting at the caret

    /// A text block from the dialog, at the caret: the editor's own insertion, through a
    /// zero-length trigger session so the block goes through the same import path as `!`.
    func insert(textBlock: EditorTextBlock) {
        let caret = document.textView?.selectedRange() ?? NSRange(location: document.storage.length, length: 0)
        document.trigger = TriggerSession(
            kind: .textBlock, range: NSRange(location: caret.location, length: 0), query: "", caretRect: .zero)
        if document.mode == .plain {
            let text = Self.plainText(fromHTML: textBlock.html)
            document.insertTextBlock(EditorTextBlock(title: textBlock.title, html: QuoteBlock.escape(text)))
        } else {
            document.insertTextBlock(textBlock)
        }
    }

    func insert(link: SmartPickerLink) {
        let caret = document.textView?.selectedRange() ?? NSRange(location: document.storage.length, length: 0)
        document.trigger = TriggerSession(
            kind: .smartPicker, range: NSRange(location: caret.location, length: 0), query: "", caretRect: .zero)
        document.insertSmartPickerLink(link)
    }

    // MARK: - Sending

    /// Send, unless a pre-send warning (no subject, forgotten attachment) needs answering
    /// first; "Send anyway" then calls ``confirmSend()``, which skips both.
    func requestSend(at date: Date? = nil) {
        guard canSend else { return }
        let current = warnings
        let blocking = [ComposerWarning.noSubject, .forgottenAttachment].filter(current.contains)
        if !blocking.isEmpty {
            pendingSendAt = date
            pendingWarnings = blocking
            return
        }
        Task { await send(at: date) }
    }

    func confirmSend() {
        let date = pendingSendAt
        pendingWarnings = []
        pendingSendAt = nil
        Task { await send(at: date) }
    }

    /// Hands the draft to the drafts engine. The window hides; the row decides what next.
    func send(at date: Date? = nil) async {
        guard canSend else { return }
        if let date { sendAt = date }
        hasChanges = true
        await writeNow()
        guard let draftId, let outbox else {
            sendError = String(localized: "Could not send message")
            return
        }
        do {
            try await outbox.send(draftId: draftId, sendAt: sendAt)
            sendError = nil
            phase = .sending
            hide()
        } catch {
            Self.logger.error("send did not start: \(String(describing: error), privacy: .public)")
            sendError = String(localized: "Could not send message")
        }
    }

    /// Follows the row: gone means sent (or filed), a cleared state means undone, `failed`
    /// means back to editing with the reason.
    private func observeRow() {
        guard rowObservation == nil, let draftId, let accountId else { return }
        let store = session.store
        rowObservation = Task { [weak self] in
            do {
                for try await drafts in store.observeDrafts(accountId: accountId) {
                    guard let self else { return }
                    let row = drafts.first { $0.id == draftId }
                    await self.rowChanged(row)
                }
            } catch {
                Self.logger.error("draft row observation stopped")
            }
        }
    }

    private func rowChanged(_ row: DraftRecord?) async {
        guard let row else {
            // The engine dropped the row: sent, moved to Drafts, or discarded.
            if phase == .sending { await finishAfterSend() }
            return
        }
        if row.remoteId != nil, replacesOutboxId != nil, !outboxCancelled {
            await cancelReplacedOutbox()
        }
        switch row.sendState.flatMap(DraftSendState.init(rawValue:)) {
        case nil:
            saveStatus =
                row.syncError.map { .failed($0) }
                ?? (row.savedAt.map { $0 >= row.updatedAt } == true ? .saved : .saving)
            if phase == .sending {
                // Undone in the banner: "Edit message" (§6.9).
                phase = .editing
                kind = .outbox
                reveal()
            }
        case .failed:
            if phase == .sending {
                phase = .editing
                sendError = row.syncError ?? String(localized: "Could not send message")
                reveal()
            }
        case .undo, .queued, .sending, .closing:
            break
        }
    }

    /// An outbox edit replaces the server entry (Main's WS-27 decision). Without
    /// attachments it is cancelled on open, which pauses the schedule; with them it waits
    /// for this draft's first server save, which re-links the uploads to the new message
    /// so deleting the old entry no longer deletes them.
    private func cancelReplacedOutbox() async {
        guard let outboxId = replacesOutboxId, !outboxCancelled, let outbox else { return }
        outboxCancelled = true
        do {
            try await outbox.deleteOutbox(outboxId: outboxId)
        } catch {
            outboxCancelled = false
            Self.logger.error("replaced outbox entry not cancelled: \(String(describing: error), privacy: .public)")
        }
    }

    /// The opened outbox entry is cancelled straight away when it carries no uploads.
    func cancelOutboxIfSafe() async {
        guard kind == .outbox, replacesOutboxId != nil, attachments.allSatisfy({ $0.kind != "outbox" }) else { return }
        await cancelReplacedOutbox()
    }

    private func finishAfterSend() async {
        if replacesOutboxId != nil, !outboxCancelled { await cancelReplacedOutbox() }
        finish()
    }

    // MARK: - Closing

    /// The window closed: write, then hand the draft to the engine's close, which files it
    /// in Drafts (§6.3). An edited outbox entry with a future send time is re-scheduled
    /// instead, which restores its send time as the web client does.
    func windowClosed() {
        guard phase == .editing else {
            if phase != .sending { finish() }
            return
        }
        let draftId = draftId
        let outbox = outbox
        let restoreAt = kind == .outbox ? sendAt.flatMap { $0 > Date() ? $0 : nil } : nil
        phase = .finished
        Task {
            await writeNowForClose()
            guard let draftId, let outbox else {
                ComposerWindows.shared.unregister(self)
                return
            }
            if let restoreAt, (try? await outbox.send(draftId: draftId, sendAt: restoreAt)) != nil {
                Self.logger.info("edited outbox entry re-scheduled on close")
            } else {
                await outbox.closeDraft(draftId)
            }
            ComposerWindows.shared.unregister(self)
        }
        stopObserving()
    }

    private func writeNowForClose() async {
        let saved = phase
        phase = .editing
        await writeNow()
        phase = saved
    }

    /// "Discard & close draft" (§6.9).
    func discard() {
        let draftId = draftId
        let outbox = outbox
        phase = .finished
        stopObserving()
        Task {
            if let draftId, let outbox {
                for row in (try? await session.store.attachments(draftId: draftId)) ?? [] {
                    if let path = row.localPath { AttachmentStaging.discard(path: path) }
                }
                await outbox.discardDraft(draftId)
                notice = String(localized: "Message discarded")
            }
            ComposerWindows.shared.unregister(self)
        }
        dismiss?()
    }

    /// Quit: save to Drafts or discard, then the app terminates.
    func closeForQuit(discard: Bool) async {
        guard let draftId, let outbox else { return }
        if discard {
            await outbox.discardDraft(draftId)
        } else {
            await writeNow()
            await outbox.closeDraft(draftId)
        }
        phase = .finished
    }

    private func finish() {
        phase = .finished
        stopObserving()
        ComposerWindows.shared.unregister(self)
        dismiss?()
    }

    private func stopObserving() {
        rowObservation?.cancel()
        rowObservation = nil
        writeTask?.cancel()
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        editObserver = nil
    }

    // MARK: - Window

    func reveal() {
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

extension ComposerModel {
    /// HTML to text through the editor's own importer and serialiser, never WebKit.
    static func plainText(fromHTML html: String) -> String {
        PlainTextSerializer.text(
            from: HTMLImporter.attributedString(fromHTML: html, baseFont: EditorFontMetrics.defaultBaseFont))
    }

    /// The account of the mailbox on screen, which a new message is sent from (§6.2).
    fileprivate func currentAccountId() async -> Int64? {
        guard let mailboxId = session.selectedMailboxId() else { return nil }
        return try? await session.store.mailbox(id: mailboxId)?.accountId
    }
}
