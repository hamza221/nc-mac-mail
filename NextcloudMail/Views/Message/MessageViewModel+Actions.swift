// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import NCMailCore
import NCMailStore
import NCMailSync

/// The v2 features of the message view, each through one of the three engine doors in
/// ``MessageViewServices``: a `serverResult` request plus an observation of its row, a queue
/// row, or an export to a file the reader chose. None of them awaits a response to draw it.
extension MessageViewModel {
    /// The IMAP keyword the follow-up feature tags a sent message with.
    static let followUpLabel = "$follow_up"

    var isFollowUp: Bool { tags.contains { $0.imapLabel == Self.followUpLabel } }

    /// Smart replies, per the web's gates: not where free prompt is known off, not in Trash
    /// or Junk, and not on a follow-up, which is answered with "Follow up" instead.
    var offersSmartReplies: Bool {
        login?.llmFreepromptAvailable != false && !["trash", "junk"].contains(mailboxRole ?? "") && !isFollowUp
    }

    /// The translation affordances are hidden only when the instance said translation is off;
    /// unknown is offered and the server's answer decides (server-flags.md, "Partly").
    var offersTranslation: Bool { login?.llmTranslationEnabled != false && !security.isPGP }

    /// The follow-up banner: the tag is there and the check has not seen an answer.
    var showsFollowUpBanner: Bool { isFollowUp && !followUpAnswered }

    /// The sender's domain, for "Always show images from {domain}".
    var senderDomain: String? {
        guard let email = header?.sender?.email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
        return domain.isEmpty ? nil : domain
    }

    // MARK: - Server results (ADR-0067)

    /// The expanded message's results: smart replies and, on a follow-up, the check.
    func requestPerMessageResults() {
        guard let id = expandedId else { return }
        let key = ServerResultKind.messageKey(id)
        if offersSmartReplies {
            set(smartReplies: .pending)
            watch(.smartReply, key: key) { model, payload in
                guard model.expandedId == id else { return }
                model.set(smartReplies: Self.state(payload, Self.replies(in:)))
            }
        }
        if isFollowUp {
            watch(.followUp, key: key) { model, payload in
                guard model.expandedId == id, case .ready(let data)? = payload else { return }
                model.set(followUpAnswered: data.objectValue?["wasFollowedUp"] == .bool(true))
            }
        }
    }

    /// The summary of a conversation of three or more, the web's `Thread.vue` gate: counted
    /// across the account (``conversationSize``), not just this mailbox's part of it, and
    /// keyed by the oldest message shown — the server summarises that message's thread root.
    /// Asked once the login is known: the row lives under it.
    func requestThreadSummary() {
        guard threadSummary == .idle, conversationSize >= 3, resolvedLoginId != nil,
            login?.llmSummariesAvailable != false, let first = thread.first
        else { return }
        set(threadSummary: .pending)
        watch(.threadSummary, key: ServerResultKind.messageKey(first.id)) { model, payload in
            model.set(threadSummary: Self.state(payload) { $0.stringValue.flatMap { $0.isEmpty ? nil : $0 } })
        }
    }

    /// "View source": the row if it is there, a request if it is not.
    func requestSource() {
        guard let id = expandedId else { return }
        if source == .idle { set(source: .pending) }
        watch(.messageSource, key: ServerResultKind.messageKey(id)) { model, payload in
            guard model.expandedId == id else { return }
            model.set(source: Self.state(payload) { $0.objectValue?["source"]?.stringValue })
        }
    }

    /// Asks for a translation into `target`, from `source` or detected. A new pair clears
    /// the old result, as the web's modal does.
    func requestTranslation(to target: String, from sourceLanguage: String?) {
        guard let id = expandedId else { return }
        set(translation: .pending)
        let markup = translatesMarkup
        let key = ServerResultKind.translationKey(messageId: id, to: target, from: sourceLanguage)
        watch(.translation, key: key) { model, payload in
            guard model.expandedId == id else { return }
            model.set(
                translation: Self.state(payload) { data in
                    guard let text = data.objectValue?["text"]?.stringValue, !text.isEmpty else { return nil }
                    // Never rendered: the provider's output did not pass the server's purifier.
                    return markup ? HTMLPlainText.text(of: text) : text
                }
            )
        }
    }

    func clearTranslation() {
        set(translation: .idle)
    }

    /// A row's payload as the view's state; nil until the row exists is pending.
    nonisolated static func state<Value>(
        _ payload: ServerResultPayload?,
        _ value: (AnyJSON) -> Value?
    ) -> ServerResultState<Value> {
        switch payload {
        case nil: return .pending
        case .empty?: return .empty
        case .failed?: return .failed
        case .ready(let data)?: return value(data).map(ServerResultState.ready) ?? .empty
        }
    }

    /// The smart-reply row's data: the server's list of reply strings, as the fetcher stores
    /// the route's bare array (recorded live, `message-smartreply-populated.json`). Blank
    /// entries are dropped and at most three are shown.
    nonisolated static func replies(in data: AnyJSON) -> [String]? {
        guard case .array(let items) = data else { return nil }
        let cleaned = items.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : Array(cleaned.prefix(3))
    }

    // MARK: - Queue rows

    /// One queued operation on the expanded message's account, with the web's toast as the
    /// notice. The local effect lands in the same transaction as the row, and the thread
    /// observation redraws from it.
    func perform(_ operation: MailOperation, notice: String? = nil, failure: String) async {
        guard let header else { return }
        guard let queue = services.queue else {
            actionError = failure
            return
        }
        do {
            try await queue.perform(operation, accountId: header.accountId)
            actionError = nil
            actionNotice = notice
            await reloadEnvelope()
        } catch {
            actionError = failure
            renderLog.error("message action failed: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    func sendReadReceipt() async {
        guard let id = expandedId else { return }
        await perform(.sendMDN(messageId: id), failure: String(localized: "Could not send mdn"))
        if actionError == nil { markReadReceiptSent() }
    }

    func unsubscribeOneClick() async {
        guard let id = expandedId else { return }
        await perform(
            .unsubscribe(messageId: id),
            notice: String(localized: "Unsubscribe request sent"),
            failure: String(localized: "Could not unsubscribe from mailing list")
        )
    }

    func disableFollowUpReminder() async {
        guard let id = expandedId else { return }
        await perform(
            .unsetTag(messageIds: [id], imapLabel: Self.followUpLabel),
            failure: String(localized: "Could not disable the reminder")
        )
    }

    /// Star, important and read, each the opposite of what the expanded message has now.
    func toggle(flag: MessageFlagToggle) async {
        guard let header, let id = expandedId else { return }
        let (key, value): (String, Bool) =
            switch flag {
            case .star: ("flagged", !header.isFlagged)
            case .important: ("important", !header.isImportant)
            case .unread: ("seen", !header.isSeen)
            }
        await perform(
            .setFlags(messageIds: [id], flags: [key: value]),
            failure: String(localized: "Could not update the message")
        )
    }

    /// "Always show images from {domain}": queued for the login, and shown now.
    func trustSenderDomain() async {
        guard let domain = senderDomain else { return }
        showImages()
        await perform(
            .trustDomain(domain: domain, trusted: true),
            failure: String(localized: "Could not trust this domain")
        )
    }

    /// One queued `saveToFiles` per id; nil is the whole message as `.eml`.
    func saveToFiles(attachmentIds: [String?], targetPath: String) async {
        guard let id = expandedId else { return }
        let message = attachmentIds == [nil]
        for attachmentId in attachmentIds {
            await perform(
                .saveToFiles(messageId: id, attachmentId: attachmentId, targetPath: targetPath),
                notice: message
                    ? String(localized: "Message saved to Files")
                    : attachmentIds.count > 1
                        ? String(localized: "Attachments saved to Files")
                        : String(localized: "Attachment saved to Files"),
                failure: message
                    ? String(localized: "Message could not be saved")
                    : attachmentIds.count > 1
                        ? String(localized: "Error while saving attachments")
                        : String(localized: "Attachment could not be saved")
            )
            guard actionError == nil else { return }
        }
    }

    // MARK: - Files on this Mac

    /// `.eml`, zip or one attachment, to a file the reader chose in a save panel.
    func export(_ what: MessageExport, to url: URL) async {
        guard let id = expandedId else { return }
        guard let exporter = services.exporter else {
            actionError = String(localized: "This download needs a connection to the server.")
            return
        }
        do {
            try await exporter.export(what, messageId: id, to: url)
            actionError = nil
        } catch {
            actionError = String(localized: "The download failed.")
            renderLog.error("export failed: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// Quick Look, for any type it can show: the mirror's bytes when it has them, otherwise
    /// the exporter writes the attachment to a temporary file first.
    func preview(_ attachment: AttachmentRecord) async {
        do {
            let url = try Self.previewLocation(for: attachment)
            if let data = attachment.data, !data.isEmpty {
                try data.write(to: url, options: .atomic)
            } else {
                guard let exporter = services.exporter, let id = expandedId else {
                    throw MailAssetError.notStored
                }
                try await exporter.export(.attachment(id: attachment.attachmentId), messageId: id, to: url)
            }
            actionError = nil
            previewURL = url
        } catch {
            actionError = String(localized: "That attachment could not be opened.")
            renderLog.error("attachment preview failed: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// Into the container's temporary directory, which Quick Look can read and nothing
    /// outside the sandbox can, under a per-attachment folder so two `logo.png` do not meet.
    nonisolated static func previewLocation(for attachment: AttachmentRecord) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "attachments", directoryHint: .isDirectory)
            .appending(
                path: "\(attachment.messageId)-\(sanitisedFileName(attachment.attachmentId))",
                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(
            path: sanitisedFileName(attachment.fileName ?? "attachment"),
            directoryHint: .notDirectory
        )
    }

    /// A file name from a message is attacker-controlled: `../../Library/…` is a real
    /// attachment name, and neither a save panel nor a temporary folder is the place to find
    /// that out.
    nonisolated static func sanitisedFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) { return "attachment" }
        return trimmed
    }

    // MARK: - Direct link

    /// Copies `ncmail://open/<Message-ID>`; false when the message has no Message-ID.
    @discardableResult
    func copyDirectLink() -> Bool {
        guard let url = MessageDirectLink.url(messageIdHeader: header?.messageIdHeader) else {
            actionError = String(localized: "Could not generate direct link: Message ID is missing")
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        actionError = nil
        actionNotice = String(localized: "Direct link copied to clipboard")
        return true
    }

    // MARK: - Printing

    /// The expanded message as drawn, or nil while there is no body to put on paper.
    var printable: PrintableMessage? {
        guard let header, let body = PrintableMessage.Body(presentation) else { return nil }
        return PrintableMessage(header: header, body: body)
    }

    /// Every message of the conversation, read from the mirror now: the expanded one as it
    /// is drawn, each collapsed one rewritten with its own policy (remote images only for a
    /// trusted sender), a body not mirrored yet as its header and a line, PGP as its header
    /// and the notice.
    func printableThread() async -> [PrintableMessage] {
        let ids = thread.isEmpty ? [expandedId].compactMap(\.self) : thread.map(\.id)
        var messages: [PrintableMessage] = []
        for id in ids {
            if id == expandedId, let printable {
                messages.append(printable)
                continue
            }
            guard let record = try? await services.store.message(id: id) else { continue }
            let addresses = (try? await services.store.addresses(messageId: id)) ?? []
            let header = Self.header(from: record, addresses: addresses)
            guard let stored = try? await services.store.body(messageId: id) else {
                messages.append(
                    PrintableMessage(
                        header: header,
                        body: .headerOnly(note: String(localized: "This message has not been downloaded yet."))
                    )
                )
                continue
            }
            let smime = SMimeStatus(json: stored.body.smimeJSON)
            if MessageSecurityInfo.isPGP(
                envelopeEncrypted: record.isEncrypted,
                smimeEncrypted: smime?.isEncrypted ?? false,
                plainBody: stored.body.hasHtmlBody ? nil : stored.body.plainBody
            ) {
                messages.append(PrintableMessage(header: header, body: .headerOnly(note: MessagePGPNotice.text)))
                continue
            }
            let rendered = await Self.render(
                stored.body,
                header: header,
                server: services.server,
                showsRemoteImages: stored.body.isSenderTrusted
            )
            if let body = PrintableMessage.Body(rendered.presentation) {
                messages.append(PrintableMessage(header: header, body: body))
            }
        }
        return messages
    }
}

/// The three per-message flags the ⋯ menu toggles.
enum MessageFlagToggle {
    case star
    case important
    case unread
}
