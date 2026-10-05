// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailSync
import OSLog

/// Where one mail account's Files live: its login row and that login's Files engine.
struct FilesContext {
    let loginId: Int64
    /// Nil until `AccountEngine` has started the login; reading the cache still works.
    let sync: FilesListingSync?

    @MainActor
    static func resolve(accountId: Int64, session: AppSession) async -> FilesContext? {
        guard
            let account = try? await session.store.account(id: accountId),
            let loginId = try? await session.store.login(
                for: ServerIdentity(serverURL: account.serverURL, loginName: account.loginName))?.id
        else { return nil }
        let sessionId = AccountSession.identifier(server: account.serverURL, loginName: account.loginName)
        return FilesContext(loginId: loginId, sync: session.engine.files(sessionId: sessionId))
    }
}

/// Why a Files action did not happen, worded for the alert that shows it.
enum FilesActionError: Error, Equatable {
    case tooLarge
    case unsupportedType
    case offline
    /// The account's engine is not running (signed out, or still starting).
    case unavailable
    case failed(String)

    var message: String {
        switch self {
        case .tooLarge: "The selected image is too large to embed."
        case .unsupportedType: "Only PNG, JPEG, GIF, BMP and WebP images can be embedded."
        case .offline: "This needs a connection to your Nextcloud."
        case .unavailable: "Files is not available for this account right now."
        case .failed(let reason): "Nextcloud could not do that (\(reason))."
        }
    }
}

/// The Files actions the composer (WS-27) and the message view (WS-30) call. None of them
/// touches the network: each writes a row, queues an operation, or asks `FilesListingSync`
/// and reads what it wrote.
@MainActor
enum FilesActions {
    nonisolated private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "files")

    // MARK: Attach from Files

    /// One `draftAttachment` row of kind `cloud` per file. Local, so it works offline; the
    /// server copies each file into the message when the draft is saved or sent. The caller
    /// saves the draft as after any other attachment change.
    static func attach(_ entries: [FilesEntry], draftId: Int64, store: MailStore) async throws {
        for entry in entries where !entry.isFolder {
            _ = try await store.insert(draftAttachment: entry.draftAttachment(draftId: draftId))
        }
    }

    // MARK: Insert image from Files

    static func insertImage(
        _ entry: FilesEntry, accountId: Int64, into document: EditorDocument, session: AppSession
    ) async -> FilesActionError? {
        if let refusal = refusal(for: entry) { return refusal }
        guard !session.status.isOffline else { return .offline }
        guard let context = await FilesContext.resolve(accountId: accountId, session: session),
            let sync = context.sync
        else { return .unavailable }
        return await insertImage(
            entry, sync: sync, store: session.store, loginId: context.loginId,
            insert: { document.insertImage(at: $0) })
    }

    /// The engine-level half, separated so a test can drive it with a fake transport.
    static func insertImage(
        _ entry: FilesEntry,
        sync: FilesListingSync,
        store: MailStore,
        loginId: Int64,
        insert: (URL) -> Void
    ) async -> FilesActionError? {
        if let refusal = refusal(for: entry) { return refusal }
        let outcome = await sync.stageImage(entry)
        if case .failure(let error) = outcome { return failure(error) }
        guard
            let row = try? await store.serverResult(
                kind: FilesListingSync.imageKind, key: FilesPath.normalize(entry.path), loginId: loginId),
            let file = FilesListingSync.stagedImageURL(in: row)
        else { return .failed("missing") }
        // The editor embeds the bytes as a data: URL, so the staged copy is spent.
        insert(file)
        try? FileManager.default.removeItem(at: file)
        return nil
    }

    /// The limit and the types, checked before anything is asked of the server.
    static func refusal(for entry: FilesEntry) -> FilesActionError? {
        guard !entry.isFolder, let mime = entry.mime, FilesListingSync.imageTypes.contains(mime) else {
            return .unsupportedType
        }
        guard (entry.size ?? 0) <= FilesListingSync.maximumImageBytes else { return .tooLarge }
        return nil
    }

    // MARK: Share link

    /// Creates one public link per file and inserts each URL at the caret, in order.
    static func insertShareLinks(
        _ entries: [FilesEntry], accountId: Int64, into document: EditorDocument, session: AppSession
    ) async -> FilesActionError? {
        guard !session.status.isOffline else { return .offline }
        guard let context = await FilesContext.resolve(accountId: accountId, session: session),
            let sync = context.sync
        else { return .unavailable }
        for (index, entry) in entries.enumerated() {
            switch await shareLink(for: entry, sync: sync, store: session.store, loginId: context.loginId) {
            case .success(let url):
                document.applyLink(url)
                // Several links are separated by an unlinked space, so they stay distinct.
                if index < entries.count - 1, let textView = document.textView {
                    textView.insertText(
                        NSAttributedString(string: " ", attributes: document.baseAttributes()),
                        replacementRange: textView.selectedRange())
                }
            case .failure(let error):
                return error
            }
        }
        return nil
    }

    static func shareLink(
        for entry: FilesEntry, sync: FilesListingSync, store: MailStore, loginId: Int64
    ) async -> Result<URL, FilesActionError> {
        let outcome = await sync.createShareLink(path: entry.path)
        if case .failure(let error) = outcome { return .failure(failure(error)) }
        guard
            let row = try? await store.serverResult(
                kind: FilesListingSync.shareLinkKind, key: FilesPath.normalize(entry.path), loginId: loginId),
            let url = FilesListingSync.shareLinkURL(in: row)
        else { return .failure(.failed("missing")) }
        return .success(url)
    }

    // MARK: Save to Files

    /// One queued `saveToFiles` per attachment id; a nil id saves the whole message as
    /// `.eml`. Queued, so it works offline and survives a quit.
    static func saveToFiles(
        messageId: Int64, attachmentIds: [String?], targetPath: String, accountId: Int64, session: AppSession
    ) async throws {
        let queue = session.engine.mutationQueue(accountId: accountId)
        let target = FilesPath.normalize(targetPath)
        for attachmentId in attachmentIds {
            try await queue.perform(
                .saveToFiles(messageId: messageId, attachmentId: attachmentId, targetPath: target),
                accountId: accountId)
        }
    }

    private static func failure(_ error: MailError) -> FilesActionError {
        switch error {
        case .server(413, _): return .tooLarge
        case .server(415, _): return .unsupportedType
        case .transport: return .offline
        default:
            logger.error("files action failed: \(error.description, privacy: .public)")
            return .failed(error.description)
        }
    }
}
