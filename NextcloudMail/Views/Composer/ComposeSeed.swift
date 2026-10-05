// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import OSLog

/// Everything a composer starts with, built from a ``ComposeRequest`` and the mirror.
///
/// Routing every request case is here and only here, so "what does Reply all prefill" is
/// one function a test can call with a store, rather than logic smeared through a view.
nonisolated struct ComposeSeed: Sendable {
    enum Kind: Equatable, Sendable {
        case new
        case reply
        case forward
        case draft
        case outbox
    }

    /// An attachment that is not a local file: a forwarded message, one of its parts, or a
    /// mirrored outbox upload. `payloadJSON` is what the send API reads for that kind.
    struct Attachment: Equatable, Sendable {
        var kind: String
        var fileName: String
        var mime: String?
        var size: Int64?
        var payloadJSON: String
        var localPath: String?
    }

    var kind: Kind = .new
    var accountId: Int64?
    var aliasId: Int64?
    var to: [ComposerAddress] = []
    var cc: [ComposerAddress] = []
    var bcc: [ComposerAddress] = []
    var subject = ""
    /// Starting editor content. HTML when `bodyIsHTML`, text otherwise.
    var body = ""
    var bodyIsHTML = false
    /// The read-only original under the editor (ADR-0065): sanitised server HTML.
    var quoteHTML: String?
    var quotePlain: String?
    var inReplyToMessageId: String?
    var replacesMessageId: Int64?
    var attachments: [Attachment] = []
    /// Shown once in the composer: "Attachments were not copied…".
    var notice: String?
    /// New, reply and forward get the signature; reopening a draft does not (§6.6).
    var insertsSignature = true
    /// The addresses being answered, for the noreply warning.
    var replyingTo: [ComposerAddress] = []
    var sendAt: Date?
    var requestMdn = false
    var isAiGenerated = false
    var smimeSign = false
    var smimeEncrypt = false
    /// Focus starts in To for a new message and in the body for a reply (§6.4).
    var focusesBody = false
    /// The mirrored outbox entry this composer replaces (Main's WS-27 decision: an
    /// outbox edit becomes a local draft and the server entry is cancelled on open).
    var replacesOutboxId: Int64?
    /// The request could not be satisfied (message gone, shared item missing): says why.
    var failure: String?
}

@MainActor
enum ComposeSeedBuilder {
    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "composer")

    /// - Parameters:
    ///   - preferredAccountId: the account of the mailbox on screen, for a new message with
    ///     none named (§6.2: preselected from the current route).
    ///   - waitForBody: asks the mirror for a missing body and waits for it; a reply quoting
    ///     a body that never arrived falls back to the preview text.
    static func seed(
        for request: ComposeRequest,
        store: MailStore,
        preferredAccountId: Int64?,
        waitForBody: @MainActor (Int64) async -> StoredBody? = { _ in nil }
    ) async -> ComposeSeed {
        do {
            switch request {
            case .new(let accountId, let mailto):
                return try await newMessage(
                    accountId: accountId ?? preferredAccountId, mailto: mailto, store: store)
            case .reply(let messageId, let mode):
                return try await reply(
                    messageId: messageId, mode: mode, smartText: nil, store: store, waitForBody: waitForBody)
            case .smartReply(let messageId, let text):
                return try await reply(
                    messageId: messageId, mode: .sender, smartText: text, store: store, waitForBody: waitForBody)
            case .forward(let messageIds, let asAttachment):
                return try await forward(
                    messageIds: messageIds, asAttachment: asAttachment, store: store, waitForBody: waitForBody)
            case .editAsNew(let messageId):
                return try await editAsNew(messageId: messageId, store: store, waitForBody: waitForBody)
            case .draft(let messageId):
                return try await draft(messageId: messageId, store: store, waitForBody: waitForBody)
            case .outbox(let outboxId):
                return try await outbox(outboxId: outboxId, store: store)
            case .shared(let inboxItemId):
                return try await shared(itemId: inboxItemId, preferredAccountId: preferredAccountId, store: store)
            }
        } catch {
            logger.error("compose seed failed: \(String(describing: error), privacy: .public)")
            var seed = ComposeSeed()
            seed.accountId = preferredAccountId
            seed.failure = String(localized: "The message could not be found.")
            return seed
        }
    }

    // MARK: - Cases

    static func newMessage(accountId: Int64?, mailto: URL?, store: MailStore) async throws -> ComposeSeed {
        var seed = ComposeSeed()
        seed.accountId = try await resolveAccount(accountId, store: store)
        if let mailto, let fields = MailtoFields(url: mailto) {
            seed.to = fields.to
            seed.cc = fields.cc
            seed.bcc = fields.bcc
            seed.subject = fields.subject ?? ""
            seed.body = fields.body ?? ""
            seed.bodyIsHTML = fields.bodyIsHTML
            seed.focusesBody = !fields.to.isEmpty
        }
        return seed
    }

    static func reply(
        messageId: Int64,
        mode: ReplyMode,
        smartText: String?,
        store: MailStore,
        waitForBody: @MainActor (Int64) async -> StoredBody?
    ) async throws -> ComposeSeed {
        let original = try await Original.load(messageId, store: store, waitForBody: waitForBody)
        var seed = ComposeSeed()
        seed.kind = .reply
        seed.accountId = original.message.accountId
        seed.aliasId = try await aliasMatching(
            original.allRecipients, accountId: original.message.accountId, store: store)
        let own = try await ownAddresses(accountId: original.message.accountId, store: store)
        let recipients = ReplyRecipients.build(original.replyInput, mode: mode, own: own)
        seed.to = recipients.to
        seed.cc = recipients.cc
        seed.replyingTo = recipients.to
        seed.subject = SubjectPrefix.reply(original.message.subject ?? "")
        seed.inReplyToMessageId = original.message.messageId
        seed.focusesBody = true
        let header = QuoteBlock.header(from: original.from.first, date: original.date)
        if let html = original.html {
            seed.quoteHTML = QuoteBlock.replyHTML(header: header, body: html)
        }
        seed.quotePlain = QuoteBlock.replyPlain(header: header, body: original.plain)
        // A reply copies the original's inline images, so a quoted picture still shows.
        seed.attachments = original.partAttachments(inlineOnly: true)
        if let smartText {
            seed.body = smartText
            seed.isAiGenerated = true
        }
        return seed
    }

    static func forward(
        messageIds: [Int64],
        asAttachment: Bool,
        store: MailStore,
        waitForBody: @MainActor (Int64) async -> StoredBody?
    ) async throws -> ComposeSeed {
        guard let firstId = messageIds.first else { throw ComposeSeedError.notFound }
        var seed = ComposeSeed()
        seed.kind = .forward
        seed.focusesBody = false
        if asAttachment {
            var subjects: [String] = []
            for id in messageIds {
                guard let message = try await store.message(id: id) else { continue }
                seed.accountId = seed.accountId ?? message.accountId
                let subject = message.subject ?? ""
                subjects.append(subject)
                let fileName = "\(subject.isEmpty ? String(localized: "message") : subject).eml"
                seed.attachments.append(
                    ComposeSeed.Attachment(
                        kind: "message",
                        fileName: fileName,
                        mime: "message/rfc822",
                        payloadJSON: json(["type": "message", "id": message.remoteId, "fileName": fileName])))
            }
            guard let accountId = seed.accountId else { throw ComposeSeedError.notFound }
            seed.accountId = accountId
            seed.subject = subjects.count == 1 ? SubjectPrefix.forward(subjects[0]) : ""
            return seed
        }
        let original = try await Original.load(firstId, store: store, waitForBody: waitForBody)
        seed.accountId = original.message.accountId
        seed.aliasId = try await aliasMatching(
            original.allRecipients, accountId: original.message.accountId, store: store)
        seed.subject = SubjectPrefix.forward(original.message.subject ?? "")
        seed.inReplyToMessageId = nil
        let fields = QuoteBlock.ForwardFields(
            from: original.from.first, to: original.to, cc: original.cc, date: original.date,
            subject: original.message.subject ?? "")
        if let html = original.html {
            seed.quoteHTML = QuoteBlock.forwardHTML(fields, body: html)
        }
        seed.quotePlain = QuoteBlock.forwardPlain(fields, body: original.plain)
        // A forward carries every attachment, inline ones included (§6.1).
        seed.attachments = original.partAttachments(inlineOnly: false)
        return seed
    }

    static func editAsNew(
        messageId: Int64, store: MailStore, waitForBody: @MainActor (Int64) async -> StoredBody?
    ) async throws -> ComposeSeed {
        let original = try await Original.load(messageId, store: store, waitForBody: waitForBody)
        var seed = ComposeSeed()
        seed.accountId = original.message.accountId
        seed.to = original.to
        seed.cc = original.cc
        seed.bcc = original.bcc
        seed.subject = original.message.subject ?? ""
        seed.body = original.html ?? original.plain
        seed.bodyIsHTML = original.html != nil
        seed.insertsSignature = false
        if original.message.hasAttachments || !original.partAttachments(inlineOnly: false).isEmpty {
            seed.notice = String(localized: "Attachments were not copied. Please add them manually.")
        }
        return seed
    }

    static func draft(
        messageId: Int64, store: MailStore, waitForBody: @MainActor (Int64) async -> StoredBody?
    ) async throws -> ComposeSeed {
        let original = try await Original.load(messageId, store: store, waitForBody: waitForBody)
        var seed = ComposeSeed()
        seed.kind = .draft
        seed.accountId = original.message.accountId
        seed.aliasId = try await aliasMatching(original.from, accountId: original.message.accountId, store: store)
        seed.to = original.to
        seed.cc = original.cc
        seed.bcc = original.bcc
        seed.subject = original.message.subject ?? ""
        seed.body = original.html ?? original.plain
        seed.bodyIsHTML = original.html != nil
        seed.inReplyToMessageId = original.message.inReplyTo
        // The IMAP copy the server expunges when this draft is first saved (ADR-0083).
        seed.replacesMessageId = original.message.remoteId
        seed.insertsSignature = false
        seed.attachments = original.partAttachments(inlineOnly: false)
        seed.focusesBody = true
        return seed
    }

    static func outbox(outboxId: Int64, store: MailStore) async throws -> ComposeSeed {
        guard let record = try await store.outboxMessages().first(where: { $0.id == outboxId }) else {
            throw ComposeSeedError.notFound
        }
        let item = OutboxItem(record)
        var seed = ComposeSeed()
        seed.kind = .outbox
        seed.accountId = record.accountId
        if let aliasRemoteId = record.aliasRemoteId {
            seed.aliasId = try await store.aliases(accountId: record.accountId)
                .first { $0.remoteId == aliasRemoteId }?.id
        }
        seed.to = item.recipients.filter { $0.kind == "to" }.map { ComposerAddress(email: $0.email, label: $0.label) }
        seed.cc = item.recipients.filter { $0.kind == "cc" }.map { ComposerAddress(email: $0.email, label: $0.label) }
        seed.bcc = item.recipients.filter { $0.kind == "bcc" }.map { ComposerAddress(email: $0.email, label: $0.label) }
        seed.subject = record.subject ?? ""
        if record.isHtml, let html = record.bodyHtml {
            seed.body = html
            seed.bodyIsHTML = true
        } else {
            seed.body = record.bodyPlain ?? ""
        }
        seed.inReplyToMessageId = record.inReplyToMessageId
        seed.sendAt = record.sendAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        seed.requestMdn = record.requestMdn
        seed.smimeSign = record.smimeSign
        seed.smimeEncrypt = record.smimeEncrypt
        seed.insertsSignature = false
        seed.replacesOutboxId = outboxId
        seed.focusesBody = true
        // The server's uploads stay referenced by id; they belong to the outbox entry, so
        // that entry is only cancelled once this draft has been sent (see ComposerModel).
        seed.attachments = item.attachments.map { attachment in
            ComposeSeed.Attachment(
                kind: "outbox",
                fileName: attachment.fileName ?? String(localized: "Attachment"),
                mime: attachment.mimeType,
                payloadJSON: json(["type": "local", "id": attachment.id]))
        }
        return seed
    }

    static func shared(itemId: String, preferredAccountId: Int64?, store: MailStore) async throws -> ComposeSeed {
        var seed = ComposeSeed()
        seed.accountId = try await resolveAccount(preferredAccountId, store: store)
        guard let item = SharedInbox.take(itemId: itemId) else {
            seed.failure = String(localized: "The shared item could not be found.")
            return seed
        }
        seed.subject = item.subject ?? ""
        let text = ([item.text].compactMap { $0 } + item.urls).joined(separator: "\n")
        seed.body = text
        seed.attachments = item.stagedFiles.map {
            ComposeSeed.Attachment(
                kind: "local", fileName: $0.name, mime: $0.mime, size: $0.size, payloadJSON: "{}",
                localPath: $0.path)
        }
        return seed
    }

    // MARK: - Helpers

    /// The named account if it exists, else the first one (unified views name none).
    static func resolveAccount(_ accountId: Int64?, store: MailStore) async throws -> Int64? {
        if let accountId, try await store.account(id: accountId) != nil { return accountId }
        return try await store.accounts().first?.id
    }

    static func ownAddresses(accountId: Int64, store: MailStore) async throws -> Set<String> {
        var own: Set<String> = []
        if let account = try await store.account(id: accountId) { own.insert(account.emailAddress.lowercased()) }
        for alias in try await store.aliases(accountId: accountId) { own.insert(alias.email.lowercased()) }
        return own
    }

    /// Reply/forward from the alias the original was addressed to, as the web client does.
    static func aliasMatching(_ addresses: [ComposerAddress], accountId: Int64, store: MailStore) async throws -> Int64?
    {
        let keys = Set(addresses.map(\.key))
        return try await store.aliases(accountId: accountId).first { keys.contains($0.email.lowercased()) }?.id
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

enum ComposeSeedError: Error {
    case notFound
}

/// The message being answered, forwarded or reopened, with everything the seed needs.
@MainActor
private struct Original {
    let message: MessageRecord
    let from: [ComposerAddress]
    let to: [ComposerAddress]
    let cc: [ComposerAddress]
    let bcc: [ComposerAddress]
    let replyTo: [ComposerAddress]
    let html: String?
    let plain: String
    let body: StoredBody?
    let remoteMailboxId: Int64?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(message.sentAt)) }
    var allRecipients: [ComposerAddress] { to + cc + bcc }

    var replyInput: ReplyRecipients.Original {
        ReplyRecipients.Original(
            from: from, to: to, cc: cc, replyTo: replyTo,
            isMailingList: body?.body.unsubscribeUrl != nil || body?.body.unsubscribeMailto != nil)
    }

    static func load(
        _ messageId: Int64, store: MailStore, waitForBody: @MainActor (Int64) async -> StoredBody?
    ) async throws -> Original {
        guard let message = try await store.message(id: messageId) else { throw ComposeSeedError.notFound }
        let addresses = try await store.addresses(messageId: messageId)
        func list(_ kind: AddressKind) -> [ComposerAddress] {
            addresses.filter { $0.kind == kind }.sorted { $0.position < $1.position }
                .map { ComposerAddress(email: $0.email, label: $0.label) }
        }
        var from = list(.from)
        if from.isEmpty, let email = message.fromEmail {
            from = [ComposerAddress(email: email, label: message.fromLabel)]
        }
        var stored = try await store.body(messageId: messageId)
        if stored == nil { stored = await waitForBody(messageId) }
        let html = stored.flatMap { $0.body.hasHtmlBody ? $0.body.html : nil }.flatMap { $0.isEmpty ? nil : $0 }
        let plain = stored?.body.plainBody ?? message.previewText ?? ""
        let mailbox = try await store.mailbox(id: message.mailboxId)
        return Original(
            message: message, from: from, to: list(.to), cc: list(.cc), bcc: list(.bcc), replyTo: list(.replyTo),
            html: html, plain: plain, body: stored, remoteMailboxId: mailbox?.remoteId)
    }

    /// The original's parts as `message-attachment` payloads (the server copies them at
    /// send time from IMAP: `AttachmentService::handleForwardedAttachment`).
    func partAttachments(inlineOnly: Bool) -> [ComposeSeed.Attachment] {
        guard let body, let remoteMailboxId, let uid = message.uid else { return [] }
        return body.attachments.compactMap { attachment in
            if inlineOnly && !attachment.isInline { return nil }
            let fileName = attachment.fileName ?? String(localized: "Attachment")
            return ComposeSeed.Attachment(
                kind: attachment.isInline ? "message-attachment-inline" : "message-attachment",
                fileName: fileName,
                mime: attachment.mime,
                size: attachment.size,
                payloadJSON: ComposeSeedBuilder.json([
                    "type": attachment.isInline ? "message-attachment-inline" : "message-attachment",
                    "mailboxId": remoteMailboxId,
                    "uid": uid,
                    "id": attachment.attachmentId,
                    "fileName": fileName,
                ]))
        }
    }
}
