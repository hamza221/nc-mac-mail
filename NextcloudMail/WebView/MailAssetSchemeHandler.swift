// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import WebKit

/// Serves `ncmail://asset/…` for one message view.
///
/// An allowlist, not a proxy ([ADR-0010](../../docs/decisions/0010-webview-scheme-handler.md)).
/// It answers two shapes of URL and fails every other load:
///
/// - **an inline attachment of the message on screen**, from `attachment.data` when the
///   mirror has it, and otherwise by fetching it, writing it to the mirror, and serving what
///   the mirror now holds. The bytes the WebView receives always come out of the database,
///   so an image read once is an image that renders offline.
/// - **a proxied remote image**, and only when the reader has unblocked this message. Those
///   bytes are *not* stored and are the one place in the application where a response
///   reaches the screen without passing through the database. That is ADR-0010's deliberate
///   choice: storing a tracking pixel would give it a permanent home on the reader's disk
///   in exchange for nothing.
///
/// WebKit calls this on the main thread and expects it back immediately, so every method
/// here starts a `Task` and returns.
@MainActor
final class MailAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// What the handler is allowed to serve *right now*. Replaced, never mutated in place,
    /// when the message on screen changes or the reader unblocks it.
    nonisolated struct Context: Equatable, Sendable {
        /// The mirror's id, for reading and writing rows (ADR-0033).
        var localMessageId: Int64
        /// The server's id, for building a request and for refusing an attachment URL that
        /// names a different message.
        var remoteMessageId: Int64
        var showsRemoteImages: Bool
        /// Exactly the attachment ids the rendered document references.
        var inlineAttachmentIds: Set<String>

        static let none = Context(
            localMessageId: 0,
            remoteMessageId: 0,
            showsRemoteImages: false,
            inlineAttachmentIds: []
        )
    }

    /// What one request resolves to, decided before anything is read or fetched.
    nonisolated enum Decision: Equatable, Sendable {
        /// An inline attachment of `message`, which listed `attachmentId` as one its document
        /// references.
        case inlineAttachment(Context, attachmentId: String)
        case proxiedRemoteImage
        case refuse(MailAssetRefusal)
    }

    private let store: MailStore
    private let client: MailClient
    private let server: URL
    /// One per message in the loaded document: exactly one on screen, one per message of a
    /// whole-thread printout ([ADR-0085](../../docs/decisions/0085-thread-mode-expands-one-message-at-a-time.md)).
    private var contexts: [Context] = []
    /// Tasks WebKit has not stopped. Calling back into a stopped task raises an Objective-C
    /// exception, which is a crash rather than an error, so every callback is guarded.
    private var liveTasks: Set<ObjectIdentifier> = []

    init(store: MailStore, client: MailClient, server: URL) {
        self.store = store
        self.client = client
        self.server = server
    }

    func update(contexts: [Context]) {
        self.contexts = contexts
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        liveTasks.insert(key)
        let url = urlSchemeTask.request.url
        Task { await serve(urlSchemeTask, key: key, url: url) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: - Serving

    private func serve(_ task: any WKURLSchemeTask, key: ObjectIdentifier, url: URL?) async {
        switch Self.decide(url, server: server, contexts: contexts) {
        case .refuse(let refusal):
            refuse(task, key: key, because: refusal)
        case .inlineAttachment(let context, let attachmentId):
            guard let url else { return refuse(task, key: key, because: .notAnAssetURL) }
            await serveInlineAttachment(task, key: key, url: url, context: context, attachmentId: attachmentId)
        case .proxiedRemoteImage:
            guard let url, let target = MailAssetURL.decode(url) else {
                return refuse(task, key: key, because: .notAnAssetURL)
            }
            await serveProxiedImage(task, key: key, url: url, target: target)
        }
    }

    /// The whole allowlist for one requested URL, as a pure function so it is testable
    /// without a web view.
    ///
    /// An inline attachment is attributed to the message its own path names, and served only
    /// when that message is in `contexts` *and* lists the attachment id. A proxied image cannot
    /// be attributed — its URL names a remote host, not a message — so it is served when any
    /// listed message has remote images shown. On screen there is one context and the two
    /// rules are v1's; ADR-0085 records why a printout's weaker proxy rule still holds.
    nonisolated static func decide(_ url: URL?, server: URL, contexts: [Context]) -> Decision {
        guard let url, let target = MailAssetURL.decode(url) else { return .refuse(.notAnAssetURL) }
        guard MailAssetPolicy.isOnServer(target, server: server) else { return .refuse(.offServer) }
        var classifiedNothing = false
        for context in contexts {
            switch MailAssetPolicy.classify(target, server: server, messageRemoteId: context.remoteMessageId) {
            case .inlineAttachment(let attachmentId):
                guard context.inlineAttachmentIds.contains(attachmentId) else { return .refuse(.unknownAttachment) }
                return .inlineAttachment(context, attachmentId: attachmentId)
            case .proxiedRemoteImage:
                return contexts.contains(where: \.showsRemoteImages)
                    ? .proxiedRemoteImage : .refuse(.remoteImagesBlocked)
            case nil:
                classifiedNothing = true
            }
        }
        // `classify` refuses an attachment belonging to another message and an unrecognised
        // path with the same nil, and the two are worth telling apart in the log without
        // putting the URL in it.
        let isAttachmentPath =
            classifiedNothing
            && MailAssetPolicy.relativePath(of: target, server: server)?.contains("/attachment/") == true
        return .refuse(isAttachmentPath ? .otherMessage : .notAnAllowedPath)
    }

    private func serveInlineAttachment(
        _ task: any WKURLSchemeTask,
        key: ObjectIdentifier,
        url: URL,
        context: Context,
        attachmentId: String
    ) async {
        let messageId = context.localMessageId
        let remoteId = context.remoteMessageId
        do {
            if let served = try await storedAttachment(messageId: messageId, attachmentId: attachmentId) {
                return respond(task, key: key, url: url, data: served.data, mime: served.mime)
            }
            let (data, _) = try await client.bytes(
                .attachment(messageId: Int(remoteId), attachmentId: attachmentId)
            )
            try await store.storeInlineAttachment(
                messageId: messageId,
                attachmentId: attachmentId,
                data: data,
                fetchedAt: Int64(Date().timeIntervalSince1970)
            )
            // Read back rather than serving `data` directly: the WebView is fed from the
            // database in every path, which is what makes "read once, renders offline" a
            // property of the code and not of a comment.
            guard let served = try await storedAttachment(messageId: messageId, attachmentId: attachmentId) else {
                return fail(task, key: key, with: MailAssetError.notStored)
            }
            respond(task, key: key, url: url, data: served.data, mime: served.mime)
        } catch {
            renderLog.error("inline attachment failed: \(RenderFailure.label(error), privacy: .public)")
            fail(task, key: key, with: error)
        }
    }

    private func serveProxiedImage(
        _ task: any WKURLSchemeTask,
        key: ObjectIdentifier,
        url: URL,
        target: URL
    ) async {
        guard let endpoint = proxyEndpoint(for: target) else {
            return refuse(task, key: key, because: .notAnAllowedPath)
        }
        do {
            // The response's Content-Type is always `application/octet-stream` on this
            // endpoint, so the bytes decide (`ImageSignature`).
            let (data, _) = try await client.bytes(endpoint)
            guard let mime = ImageSignature.mimeType(of: data) else {
                return refuse(task, key: key, because: .notAnImage)
            }
            respond(task, key: key, url: url, data: data, mime: mime)
        } catch {
            renderLog.error("proxied image failed: \(RenderFailure.label(error), privacy: .public)")
            fail(task, key: key, with: error)
        }
    }

    /// The stored blob for an inline attachment, with a MIME type we are willing to render.
    private func storedAttachment(messageId: Int64, attachmentId: String) async throws -> (data: Data, mime: String)? {
        guard let body = try await store.body(messageId: messageId),
            let record = body.attachments.first(where: { $0.attachmentId == attachmentId }),
            let data = record.data, !data.isEmpty,
            let mime = record.mime, isRenderableImage(mime)
        else { return nil }
        return (data, mime)
    }

    /// `GET {server}/…/apps/mail/proxy?…`, rebuilt as an endpoint so the request carries the
    /// app password the way every other request does.
    ///
    /// The path is not taken from the URL as text: `classify` has already established that
    /// it is `apps/mail/proxy` with an optional front-controller prefix, which is ASCII with
    /// nothing to escape. The query is carried across decoded, and `Endpoint` re-encodes it.
    func proxyEndpoint(for target: URL) -> Endpoint<Data>? {
        guard let path = MailAssetPolicy.relativePath(of: target, server: server) else { return nil }
        let query = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Endpoint(
            name: "imageProxy",
            method: .get,
            base: .server,
            encodedPath: path,
            query: query,
            isRetryable: true
        )
    }

    /// Images only, and never SVG: an SVG is a document with its own external references and
    /// its own scripting model, and nothing in mail needs one.
    private func isRenderableImage(_ mime: String) -> Bool {
        let lowered = mime.lowercased()
        guard lowered.hasPrefix("image/") else { return false }
        return !lowered.hasPrefix("image/svg")
    }

    // MARK: - Replying

    private func respond(_ task: any WKURLSchemeTask, key: ObjectIdentifier, url: URL, data: Data, mime: String) {
        guard liveTasks.contains(key) else { return }
        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        liveTasks.remove(key)
    }

    private func refuse(_ task: any WKURLSchemeTask, key: ObjectIdentifier, because refusal: MailAssetRefusal) {
        renderLog.debug("asset refused: \(String(describing: refusal), privacy: .public)")
        fail(task, key: key, with: MailAssetError.refused(refusal))
    }

    private func fail(_ task: any WKURLSchemeTask, key: ObjectIdentifier, with error: any Error) {
        guard liveTasks.contains(key) else { return }
        task.didFailWithError(error)
        liveTasks.remove(key)
    }
}

nonisolated enum MailAssetError: Error, CustomStringConvertible {
    case refused(MailAssetRefusal)
    /// The fetch worked and the row did not come back, which is a mirror bug rather than a
    /// network condition.
    case notStored

    var description: String {
        switch self {
        case .refused(let refusal): "refused: \(refusal)"
        case .notStored: "the fetched attachment was not in the mirror afterwards"
        }
    }
}
