// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import Observation
import SwiftUI

/// Raising a body's place in the backfill queue.
///
/// The only thing a message view may ask the network for, and it deliberately returns
/// nothing: `MirrorCoordinator.prioritise(messageId:)` writes the database and the view
/// updates because it is already observing the row. A view that could `await` the fetch
/// would be a view that renders from the network, which is the one thing the architecture
/// does not allow.
///
/// A protocol rather than the coordinator itself so that the app target does not import
/// `NCMailSync` for one call — see this workstream's report for the wiring WS-13 has to do.
protocol BodyPrioritising: Sendable {
    func prioritise(messageId: Int64) async
}

/// Everything the message view needs from the outside world, in one value.
///
/// Passed in rather than read from `@Environment(AppSession.self)`, because `AppSession`
/// keeps its `MailStore` private and holds no coordinator yet. Both are WS-13's to change.
struct MessageViewServices {
    var store: MailStore
    var client: MailClient
    /// The signed-in server, which is the only origin an image may come from.
    var server: URL
    var prioritiser: (any BodyPrioritising)?

    init(store: MailStore, client: MailClient, server: URL, prioritiser: (any BodyPrioritising)? = nil) {
        self.store = store
        self.client = client
        self.server = server
        self.prioritiser = prioritiser
    }
}

/// What the body area is showing.
enum MessageBodyPresentation: Equatable {
    /// The envelope is mirrored and the body is not, which is the normal state for a message
    /// the backfill has not reached. The header is already on screen; this is the area below
    /// it ([ux-spec.md](../../../docs/product/ux-spec.md#message-view)).
    case waiting
    /// The body fetch failed. Retry raises its priority again.
    case failed
    case plain(text: String, signature: String?)
    case html(RenderedMessage, MailAssetSchemeHandler.Context)
    /// The content rule list would not compile, so no body is shown at all.
    case blocked(String)
}

/// The header, assembled once per message rather than recomputed per redraw.
struct MessageHeader: Equatable {
    var messageId: Int64
    var remoteId: Int64
    var mailboxId: Int64
    var threadRootId: String?
    var subject: String?
    var sender: Address?
    var to: [Address]
    var cc: [Address]
    var sentAt: Date
    var isFlagged: Bool
    var isEncrypted: Bool
}

/// The message view's whole state, driven by the mirror.
///
/// One rule shapes every method here: nothing in this type ever reads a network response.
/// It reads the database, it asks for a body to be prioritised, and it reads the database
/// again when the database says it changed.
@MainActor
@Observable
final class MessageViewModel {
    private(set) var header: MessageHeader?
    private(set) var presentation: MessageBodyPresentation = .waiting
    private(set) var attachments: [AttachmentRecord] = []
    /// The whole thread, oldest first. Empty for a message with no thread.
    private(set) var thread: [MessageRow] = []
    private(set) var hasBlockedRemoteContent = false
    private(set) var isSenderTrusted = false
    private(set) var showsRemoteImages = false
    /// How long the last rewrite took, in milliseconds. Shown nowhere; measured because
    /// "fast enough" is not a finding.
    private(set) var lastRewriteMilliseconds: Double = 0

    /// A click waiting on a confirmation, or nil.
    var pendingLink: MessageLinkActivation?
    /// An attachment written to a temporary file for Quick Look.
    var previewURL: URL?

    /// Read by the view to build the WebView, which needs the store, the client and the
    /// server the same way this type does.
    let services: MessageViewServices
    private var messageId: Int64?
    private var observation: Task<Void, Never>?
    private var lastObservedBodyState: BodyState?

    init(services: MessageViewServices) {
        self.services = services
    }

    // MARK: - Selection

    /// Shows `messageId`, replacing whatever was being observed before.
    ///
    /// Replaced, not added to: dropping the task drops the iterator, which terminates the
    /// stream, which cancels the observation
    /// ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
    func present(messageId newId: Int64?) {
        guard newId != messageId else { return }
        observation?.cancel()
        observation = nil
        messageId = newId
        header = nil
        attachments = []
        thread = []
        hasBlockedRemoteContent = false
        isSenderTrusted = false
        showsRemoteImages = false
        lastObservedBodyState = nil
        presentation = .waiting

        guard let newId else { return }
        observation = Task { [weak self] in await self?.observe(messageId: newId) }
    }

    private func observe(messageId: Int64) async {
        await refresh(messageId: messageId)
        await prioritiseIfNeeded(messageId: messageId)

        guard let header else { return }
        // A single-message observation is what this wants and what `MailStore` does not have
        // yet. The thread query is the closest live query that covers the row: the body write
        // sets `message.bodyState` in the same transaction as the body itself
        // (`MailStore.upsert(body:for:)`), so a value arrives here exactly when the body
        // lands. The report asks WS-03 for `observeBody(messageId:)`, which turns this into
        // one line.
        do {
            for try await rows in services.store.observeThread(
                rootId: header.threadRootId ?? "",
                mailboxId: header.mailboxId
            ) {
                thread = rows
                let observed = rows.first { $0.id == messageId }?.bodyState
                let isWaiting = presentation == .waiting || presentation == .failed
                guard isWaiting || (observed != nil && observed != lastObservedBodyState) else { continue }
                await refresh(messageId: messageId)
            }
        } catch {
            renderLog.error("message observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    // MARK: - Reading the mirror

    private func refresh(messageId: Int64) async {
        guard let record = try? await services.store.message(id: messageId) else { return }
        header = Self.header(from: record)
        lastObservedBodyState = record.bodyState

        guard record.bodyState == .present else {
            attachments = []
            presentation = record.bodyState == .failed ? .failed : .waiting
            return
        }
        guard let stored = try? await services.store.body(messageId: messageId), let header else {
            presentation = .waiting
            return
        }
        attachments = stored.attachments
        isSenderTrusted = stored.body.isSenderTrusted
        await render(stored, header: header)
    }

    private func render(_ stored: StoredBody, header: MessageHeader) async {
        guard stored.body.hasHtmlBody, let html = stored.body.html, !html.isEmpty else {
            presentation = .plain(
                text: stored.body.plainBody ?? "",
                signature: stored.body.signature
            )
            hasBlockedRemoteContent = false
            return
        }

        let policy = MessageRenderPolicy(
            server: services.server,
            messageRemoteId: header.remoteId,
            showsRemoteImages: showsRemoteImages || isSenderTrusted
        )
        let fontSize = MessageDocument.preferredBaseFontSize
        let started = ContinuousClock.now
        // Off the main actor: a 5 MB body is a string walk long enough to drop frames, and
        // everything the rewriter touches is a value type.
        let rendered = await Task.detached(priority: .userInitiated) {
            MessageHTMLRewriter(policy: policy).render(fragment: html, baseFontSize: fontSize)
        }.value
        let elapsed = (ContinuousClock.now - started).components
        lastRewriteMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        hasBlockedRemoteContent = rendered.hasBlockedRemoteContent

        presentation = .html(
            rendered,
            MailAssetSchemeHandler.Context(
                localMessageId: header.messageId,
                remoteMessageId: header.remoteId,
                showsRemoteImages: policy.showsRemoteImages,
                inlineAttachmentIds: rendered.inlineAttachmentIds
            )
        )
    }

    // MARK: - The network, in the two places a view may touch it

    /// Raises this body's backfill priority. Writes the database; returns nothing.
    private func prioritiseIfNeeded(messageId: Int64) async {
        guard lastObservedBodyState != .present, let prioritiser = services.prioritiser else { return }
        await prioritiser.prioritise(messageId: messageId)
    }

    /// The Retry the UX spec puts under a failed body.
    func retry() {
        guard let messageId else { return }
        Task { await prioritiseIfNeeded(messageId: messageId) }
    }

    // MARK: - Remote content

    /// Re-renders from the stored HTML with the block lifted. No request is made here: the
    /// WebView asks for `ncmail://asset/…` when it lays the document out, and the scheme
    /// handler decides again.
    func showImages() {
        guard !showsRemoteImages, let messageId else { return }
        showsRemoteImages = true
        Task { await refresh(messageId: messageId) }
    }

    /// Show images, and tell the server, so the choice matches the web client.
    ///
    /// A mutation straight to the client rather than through the offline queue, which does
    /// not exist yet (WS-06). Noted in the report: this is the call that moves.
    func alwaysShowFromThisSender() async {
        showImages()
        guard let email = header?.sender?.email, !email.isEmpty else { return }
        do {
            _ = try await services.client.put(Endpoint.trustSender(email: email))
            isSenderTrusted = true
        } catch {
            // Nothing the reader can do about it and nothing that needs a dialogue
            // (ux-spec.md): the images are showing either way, and the next body refresh
            // carries the server's own answer.
            renderLog.error("trusting the sender failed: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// The content rule list would not compile, so nothing was rendered.
    ///
    /// Fail closed. A body drawn without the layer that blocks every non-`ncmail:` load is
    /// not a body this app shows, however unlikely the failure is.
    func contentRuleListFailed(_ reason: String) {
        presentation = .blocked(reason)
    }

    // MARK: - Attachments

    /// The bytes of an attachment, from the mirror when it has them and from the server when
    /// it does not.
    func attachmentData(_ attachment: AttachmentRecord) async throws -> Data {
        if let data = attachment.data, !data.isEmpty { return data }
        guard let header else { throw MailAssetError.notStored }
        let (data, _) = try await services.client.bytes(
            .attachment(messageId: Int(header.remoteId), attachmentId: attachment.attachmentId)
        )
        return data
    }

    // MARK: - Header

    /// The recipients come out of `message.rawJSON`.
    ///
    /// `message` denormalises the sender into two columns and keeps everybody else in
    /// `messageAddress`, which `MailStore` exposes no reader for. The raw envelope is
    /// already in the row for exactly this reason
    /// ([ADR-0020](../../../docs/decisions/0020-raw-json-in-a-wrapper.md)), so the header
    /// decodes it rather than asking for a new query.
    static func header(from record: MessageRecord) -> MessageHeader {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(record.rawJSON.utf8))
        return MessageHeader(
            messageId: record.id,
            remoteId: record.remoteId,
            mailboxId: record.mailboxId,
            threadRootId: record.threadRootId,
            subject: record.subject,
            sender: envelope?.sender ?? Address(label: record.fromLabel, email: record.fromEmail),
            to: envelope?.to ?? [],
            cc: envelope?.cc ?? [],
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.sentAt)),
            isFlagged: record.isFlagged,
            isEncrypted: record.isEncrypted
        )
    }
}
