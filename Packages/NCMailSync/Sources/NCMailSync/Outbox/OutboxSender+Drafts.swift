// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailCore
internal import NCMailNet
internal import NCMailStore

// MARK: - Plumbing

extension OutboxSender {
    var undoSeconds: Int64 { configuration.undoWindow.components.seconds }

    func cancelSaveTimer(_ draftId: Int64) {
        saveTimers.removeValue(forKey: draftId)?.cancel()
    }

    func debounceFired(_ draftId: Int64) async {
        saveTimers.removeValue(forKey: draftId)
        guard !isOffline else { return }
        await serialized(draftId) { await self.performFlush(draftId) }
    }

    /// Runs `body` after whatever this draft was already doing, and waits for it.
    func serialized<T: Sendable>(_ draftId: Int64, _ body: @escaping @Sendable () async -> T) async -> T {
        let previous = chains[draftId]
        let task = Task<T, Never> {
            await previous?.value
            return await body()
        }
        let tail = Task<Void, Never> { _ = await task.value }
        chains[draftId] = tail
        let result = await task.value
        await tail.value
        if chains[draftId] == tail { chains.removeValue(forKey: draftId) }
        return result
    }

    /// Context every request body needs and the row does not hold.
    struct AccountContext {
        var remoteAccountId: Int64
        var isDelegated: Bool
        var sentMailboxId: Int64?
        var draftsMailboxId: Int64?
    }

    func accountContext() async throws -> AccountContext {
        guard let account = try await store.account(id: accountId) else { throw OutboxError.accountNotMirrored }
        let mailboxes = try await store.mailboxes(accountId: accountId)
        // The account's role columns hold *server* mailbox ids (ADR-0033's trap); the hook
        // takes local ones.
        func local(_ remote: Int64?) -> Int64? {
            remote.flatMap { remote in mailboxes.first { $0.remoteId == remote }?.id }
        }
        return AccountContext(
            remoteAccountId: account.remoteId,
            isDelegated: account.isDelegated,
            sentMailboxId: local(account.sentMailboxId),
            draftsMailboxId: local(account.draftsMailboxId)
        )
    }

    func aliasRemoteId(_ draft: DraftRecord) async throws -> Int64? {
        guard let aliasId = draft.aliasId else { return nil }
        return try await store.aliases(accountId: accountId).first { $0.id == aliasId }?.remoteId
    }

    static func isTransport(_ error: any Error) -> Bool {
        if case MailError.transport = error { return true }
        return false
    }

    /// The user-facing reason written to `syncError`. A server message can quote an address
    /// (an SMTP rejection does), so this never goes to a log — ``logSafe(_:)`` does.
    static func reason(_ error: any Error) -> String {
        if let mail = error as? MailError {
            if case .server(_, let message?) = mail { return message }
            return mail.description
        }
        if let outbox = error as? OutboxError { return String(describing: outbox) }
        // The engine's own errors describe themselves; anything else (a store error) is
        // named by type rather than dumped, since its description can quote SQL.
        if error is StagedFileError || error is AttachmentUploadError { return String(describing: error) }
        return String(describing: type(of: error))
    }

    /// Status codes and case names only.
    static func logSafe(_ error: any Error) -> String {
        switch error {
        case let mail as MailError: mail.description
        case let outbox as OutboxError: String(describing: outbox)
        case is AttachmentUploadError: "attachmentUploadFailed"
        case is StagedFileError: "attachmentFileMissing"
        default: String(describing: type(of: error))
        }
    }
}

// MARK: - Flushing

extension OutboxSender {
    /// Every draft whose last edit the server has not seen, after a reconnect or a launch.
    func flushUnsavedDrafts() async {
        let drafts: [DraftRecord]
        do {
            drafts = try await store.unsavedDrafts().filter { $0.accountId == accountId }
        } catch {
            OutboxLog.outbox.error("unsaved drafts unreadable: \(Self.logSafe(error), privacy: .public)")
            return
        }
        for draft in drafts {
            guard !isOffline, let id = draft.id, saveTimers[id] == nil else { continue }
            await serialized(id) { await self.performFlush(id) }
        }
    }

    /// One debounced save. Skipped when nothing changed since the last one.
    func performFlush(_ draftId: Int64) async {
        do {
            guard let draft = try await store.draft(id: draftId) else { return }
            let state = draft.sendState.flatMap(DraftSendState.init(rawValue:))
            // A draft in the send pipeline is the dispatcher's; a failed one may still be
            // edited and saved.
            guard state == nil || state == .failed else { return }
            guard draft.remoteId == nil || draft.savedAt.map({ $0 < draft.updatedAt }) ?? true else { return }
            _ = try await pushDraft(draft, sendAt: draft.sendAt, uploadFailureIsFatal: false)
        } catch {
            await recordSyncError(draftId, error)
        }
    }

    /// Uploads, then creates or updates the server draft, then stamps the row.
    ///
    /// - Parameters:
    ///   - uploadFailureIsFatal: on the send path a failed upload ends the send; a save
    ///     carries on without that attachment and says so in `syncError`.
    ///   - recreateIfGone: a 404 on the update means the server's draft job moved the draft
    ///     to IMAP, and a save or a first dispatch recreates it. Recovery of a `sending` row
    ///     must not: there a 404 means the draft already became an outbox message.
    /// - Returns: the server draft id.
    func pushDraft(
        _ draft: DraftRecord,
        sendAt: Int64?,
        uploadFailureIsFatal: Bool,
        recreateIfGone: Bool = true
    ) async throws -> Int64 {
        // A record read from the table always has its id; the guard only satisfies the type.
        guard let draftId = draft.id else { throw OutboxError.noSuchDraft }
        let context = try await accountContext()
        let uploadError = try await uploadPendingAttachments(draftId, context: context)
        if let uploadError, uploadFailureIsFatal {
            throw AttachmentUploadError(reason: Self.reason(uploadError))
        }

        let body = OutboxRequest.body(
            draft: draft,
            recipients: try await store.recipients(draftId: draftId),
            attachments: try await store.attachments(draftId: draftId),
            remoteAccountId: context.remoteAccountId,
            aliasRemoteId: try await aliasRemoteId(draft),
            sendAt: sendAt,
            isCreate: draft.remoteId == nil
        )
        let remoteId: Int64
        if let existing = draft.remoteId {
            do {
                _ = try await client.put(.updateDraft(id: Int(existing)), body: body)
                remoteId = existing
            } catch MailError.notFound where recreateIfGone {
                // The server's draft job moved the idle draft to IMAP and deleted it. A new
                // one is the only way on; the moved copy stays in Drafts unless the composer
                // knew its message id (`replacesMessageId`).
                OutboxLog.outbox.info("draft \(draftId, privacy: .public) server copy gone; recreating")
                var create = body
                create.draftId = draft.replacesMessageId.map { Int($0) }
                remoteId = Int64(try await client.post(.createDraft, body: create).data.value.id)
            }
        } else {
            remoteId = Int64(try await client.post(.createDraft, body: body).data.value.id)
        }
        try await store.setDraftSync(
            id: draftId,
            remoteId: remoteId,
            savedAt: draft.updatedAt,
            syncError: uploadError.map { "attachment upload failed: \(Self.reason($0))" }
        )
        OutboxLog.outbox.info(
            "draft \(draftId, privacy: .public) saved as server draft \(remoteId, privacy: .public)"
        )
        return remoteId
    }

    /// `POST /api/attachments` for every local attachment without a server id, in order.
    ///
    /// - Returns: the first non-transport failure, after trying the rest. A transport
    ///   failure throws: nothing further can work.
    func uploadPendingAttachments(_ draftId: Int64, context: AccountContext) async throws -> (any Error)? {
        var firstFailure: (any Error)?
        for attachment in try await store.attachments(draftId: draftId)
        where attachment.kind == "local" && attachment.remoteAttachmentId == nil {
            guard let attachmentId = attachment.id else { continue }
            do {
                let data = try readStagedFile(attachment)
                var form = MultipartForm(parts: [
                    .file(
                        name: "attachment",
                        filename: attachment.fileName,
                        contentType: attachment.mime ?? "application/octet-stream",
                        data: data
                    )
                ])
                if context.isDelegated {
                    form.append(.field(name: "accountId", value: String(context.remoteAccountId)))
                }
                let uploaded = try await client.upload(.uploadAttachment, multipart: form)
                let remoteId = Int64(uploaded.id)
                try await store.setDraftRemoteAttachmentId(
                    attachmentId: attachmentId,
                    remoteAttachmentId: remoteId,
                    payloadJSON: OutboxRequest.localPayloadJSON(remoteId)
                )
                OutboxLog.outbox.info(
                    "draft \(draftId, privacy: .public) attachment \(attachmentId, privacy: .public) uploaded as \(remoteId, privacy: .public)"
                )
            } catch {
                if Self.isTransport(error) { throw error }
                OutboxLog.outbox.error(
                    "draft \(draftId, privacy: .public) attachment \(attachmentId, privacy: .public) upload failed: \(Self.logSafe(error), privacy: .public)"
                )
                if firstFailure == nil { firstFailure = error }
            }
        }
        return firstFailure
    }

    private func readStagedFile(_ attachment: DraftAttachmentRecord) throws -> Data {
        guard let path = attachment.localPath else { throw StagedFileError.missing }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw StagedFileError.missing
        }
    }

    func recordSyncError(_ draftId: Int64, _ error: any Error) async {
        OutboxLog.outbox.error(
            "draft \(draftId, privacy: .public) save failed: \(Self.logSafe(error), privacy: .public)")
        do {
            guard let draft = try await store.draft(id: draftId) else { return }
            try await store.setDraftSync(
                id: draftId,
                remoteId: draft.remoteId,
                savedAt: draft.savedAt,
                syncError: Self.reason(error)
            )
        } catch {
            OutboxLog.outbox.error("draft \(draftId, privacy: .public) error unrecordable")
        }
    }
}

/// The staged bytes of a local attachment are not on disk any more.
enum StagedFileError: Error, CustomStringConvertible {
    case missing
    var description: String { "attachment file missing" }
}

/// A send stopped because an attachment did not upload; `reason` is what the row shows.
struct AttachmentUploadError: Error, CustomStringConvertible {
    var reason: String
    var description: String { "attachment upload failed: \(reason)" }
}

// MARK: - Closing and discarding

extension OutboxSender {
    func performClose(_ draftId: Int64) async {
        do {
            guard let draft = try await store.draft(id: draftId) else { return }
            if let state = draft.sendState.flatMap(DraftSendState.init(rawValue:)), state != .closing, state != .failed
            {
                return  // in the send pipeline; the send owns it now
            }
            guard !isOffline else {
                try await markClosing(draft)
                return
            }
            var remoteId = draft.remoteId
            if remoteId == nil || draft.savedAt.map({ $0 < draft.updatedAt }) ?? true {
                remoteId = try await pushDraft(draft, sendAt: draft.sendAt, uploadFailureIsFatal: false)
            }
            guard let remoteId else { return }
            do {
                _ = try await client.post(.moveDraftToIMAP(id: Int(remoteId)))
            } catch MailError.notFound {
                // The server's own job moved it first. Same outcome.
            }
            try await store.deleteDraft(id: draftId)
            OutboxLog.outbox.info("draft \(draftId, privacy: .public) moved to IMAP drafts")
            if let drafts = try await accountContext().draftsMailboxId {
                await configuration.syncMailbox(drafts)
            }
        } catch {
            if Self.isTransport(error), let draft = try? await store.draft(id: draftId) {
                try? await markClosing(draft)
            }
            await recordSyncError(draftId, error)
        }
    }

    private func markClosing(_ draft: DraftRecord) async throws {
        guard let id = draft.id, draft.sendState != DraftSendState.closing.rawValue else { return }
        try await store.setDraftSendState(
            id: id,
            sendState: DraftSendState.closing.rawValue,
            sendRequestedAt: nil,
            syncError: nil
        )
    }

    func performDiscard(_ draftId: Int64) async {
        do {
            guard let draft = try await store.draft(id: draftId) else { return }
            if let remoteId = draft.remoteId, !isOffline {
                do {
                    _ = try await client.delete(.deleteDraft(id: Int(remoteId)))
                } catch MailError.notFound {
                    // Already moved or deleted.
                } catch  where Self.isTransport(error) {
                    // Offline after all: the server job files the orphan into Drafts.
                }
            }
            try await store.deleteDraft(id: draftId)
            OutboxLog.outbox.info("draft \(draftId, privacy: .public) discarded")
        } catch {
            OutboxLog.outbox.error(
                "draft \(draftId, privacy: .public) discard failed: \(Self.logSafe(error), privacy: .public)")
        }
    }
}
