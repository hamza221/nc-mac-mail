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
nonisolated protocol BodyPrioritising: Sendable {
    func prioritise(messageId: Int64) async
}

/// Everything the message view needs from the outside world, in one value.
///
/// Built by `AppSession.messageServices(accountId:)` for the account the selected mailbox
/// belongs to, and passed in rather than read from the environment so a test can hand the
/// view a store and a fake client without a session.
struct MessageViewServices {
    var store: MailStore
    var client: MailClient
    /// The signed-in server, which is the only origin an image may come from.
    var server: URL
    var prioritiser: (any BodyPrioritising)?
    /// Queues "always show images from this sender". A closure rather than `MessageActions`
    /// so the reader stays out of triage's type; nil leaves the choice for this message only.
    var trustSender: (@MainActor (_ email: String, _ accountId: Int64) async -> Void)?

    init(
        store: MailStore,
        client: MailClient,
        server: URL,
        prioritiser: (any BodyPrioritising)? = nil,
        trustSender: (@MainActor (_ email: String, _ accountId: Int64) async -> Void)? = nil
    ) {
        self.store = store
        self.client = client
        self.server = server
        self.prioritiser = prioritiser
        self.trustSender = trustSender
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
    /// Two observations, replaced rather than added to on every selection change. The body
    /// drives what the body area shows; the thread drives the strip underneath it.
    private var bodyObservation: Task<Void, Never>?
    private var threadObservation: Task<Void, Never>?
    private var bodyState: BodyState?

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
        bodyObservation?.cancel()
        bodyObservation = nil
        threadObservation?.cancel()
        threadObservation = nil
        messageId = newId
        header = nil
        attachments = []
        thread = []
        hasBlockedRemoteContent = false
        isSenderTrusted = false
        showsRemoteImages = false
        bodyState = nil
        presentation = .waiting

        guard let newId else { return }
        bodyObservation = Task { [weak self] in await self?.observe(messageId: newId) }
        threadObservation = Task { [weak self] in await self?.observeThread(messageId: newId) }
    }

    /// The body, live.
    ///
    /// `MailStore.upsert(body:for:)` writes the body row, its attachments and
    /// `message.bodyState` in one transaction, so a value arrives here exactly when a
    /// backfilled body lands — and the view renders it without having asked the network for
    /// anything. Until `observeBody(messageId:)` existed this rode the thread observation
    /// and compared `bodyState` by hand
    /// ([ADR-0038](../../../docs/decisions/0038-the-message-view-observes-the-thread.md)).
    private func observe(messageId: Int64) async {
        await refresh(messageId: messageId)
        await prioritiseIfNeeded(messageId: messageId)

        do {
            for try await stored in services.store.observeBody(messageId: messageId) {
                guard let stored, let header else { continue }
                attachments = stored.attachments
                isSenderTrusted = stored.body.isSenderTrusted
                bodyState = .present
                await render(stored, header: header)
            }
        } catch {
            renderLog.error("body observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// The rest of the conversation, for the strip under the body.
    ///
    /// It also carries the one thing the body observation cannot see: `bodyState` lives on
    /// `message`, and a fetch that gave up writes that column and no body row at all. A
    /// message with no `threadRootId` observes an empty thread, which still delivers —
    /// GRDB tracks the region the query reads rather than the rows it returns.
    private func observeThread(messageId: Int64) async {
        guard let record = try? await services.store.message(id: messageId) else { return }
        do {
            for try await rows in services.store.observeThread(
                rootId: record.threadRootId ?? "",
                mailboxId: record.mailboxId
            ) {
                thread = rows
                guard presentation == .waiting || presentation == .failed else { continue }
                await refresh(messageId: messageId)
            }
        } catch {
            renderLog.error("thread observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    // MARK: - Reading the mirror

    /// The envelope: the header, and what the body area says while there is no body.
    ///
    /// It deliberately does not read the body. That is ``observe(messageId:)``'s, and having
    /// one owner is what stops the same body being rendered twice when a message is opened.
    private func refresh(messageId: Int64) async {
        guard let record = try? await services.store.message(id: messageId) else { return }
        let addresses = (try? await services.store.addresses(messageId: messageId)) ?? []
        header = Self.header(from: record, addresses: addresses)
        bodyState = record.bodyState
        guard record.bodyState != .present else { return }
        attachments = []
        presentation = record.bodyState == .failed ? .failed : .waiting
    }

    /// Draws the stored body again from what is already in the mirror. No request: the only
    /// thing that changes between the two renders is a decision this process made.
    private func rerender(messageId: Int64) async {
        guard
            let stored = try? await services.store.body(messageId: messageId),
            let header
        else { return }
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
        guard bodyState != .present, let prioritiser = services.prioritiser else { return }
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
        Task { await rerender(messageId: messageId) }
    }

    /// Show images, and remember the sender, so the choice matches the web client.
    ///
    /// Through the offline queue rather than the client: the trust lands on every stored body
    /// from this sender in the same transaction as the queue row, so it holds offline and the
    /// body observation redraws with it. No request is awaited here.
    func alwaysShowFromThisSender() async {
        showImages()
        guard let email = header?.sender?.email, !email.isEmpty, let messageId else { return }
        guard let record = try? await services.store.message(id: messageId) else { return }
        await services.trustSender?(email, record.accountId)
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

    /// The recipients come out of `messageAddress`, which is the table that holds them.
    ///
    /// `message` denormalises only the sender, into `fromEmail` and `fromLabel`. This used to
    /// decode the whole envelope back out of `message.rawJSON` to list anybody else, because
    /// the table had no reader; `MailStore.addresses(messageId:)` is that reader.
    static func header(from record: MessageRecord, addresses: [MessageAddressRecord]) -> MessageHeader {
        func list(_ kind: AddressKind) -> [Address] {
            addresses.filter { $0.kind == kind }.map { Address(label: $0.label, email: $0.email) }
        }
        return MessageHeader(
            messageId: record.id,
            remoteId: record.remoteId,
            mailboxId: record.mailboxId,
            threadRootId: record.threadRootId,
            subject: record.subject,
            sender: list(.from).first ?? Address(label: record.fromLabel, email: record.fromEmail),
            to: list(.to),
            cc: list(.cc),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.sentAt)),
            isFlagged: record.isFlagged,
            isEncrypted: record.isEncrypted
        )
    }
}
