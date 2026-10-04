// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailCore
import NCMailNet
import NCMailStore
import NCMailSync
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
///
/// The three engine seams v2 adds are each a door that writes and returns nothing a view
/// renders: `serverResults` registers interest in a `serverResult` row (ADR-0067), `queue`
/// writes a queue row and its local effect, and `exporter` writes a file the reader picked.
struct MessageViewServices {
    var store: MailStore
    var client: MailClient
    /// The signed-in server, which is the only origin an image may come from.
    var server: URL
    var prioritiser: (any BodyPrioritising)?
    /// Queues "always show images from this sender". A closure rather than `MessageActions`
    /// so the reader stays out of triage's type; nil leaves the choice for this message only.
    var trustSender: (@MainActor (_ email: String, _ accountId: Int64) async -> Void)?
    /// The login's on-demand results: smart replies, the thread summary, follow-up checks,
    /// translations and the message source.
    var serverResults: ServerResultFetcher?
    /// The account's offline queue: read receipts, unsubscribe, flags, tags, trusted
    /// domains and save-to-Files.
    var queue: MutationQueue?
    /// `.eml`, zip and attachment downloads to a file the reader chose.
    var exporter: MessageExporter?
    /// Marks a message read after the reader's delay, for a message expanded in the thread
    /// rather than selected in the list (the list's selection already does it).
    var messageOpened: (@MainActor (_ messageId: Int64) async -> Void)?

    init(
        store: MailStore,
        client: MailClient,
        server: URL,
        prioritiser: (any BodyPrioritising)? = nil,
        trustSender: (@MainActor (_ email: String, _ accountId: Int64) async -> Void)? = nil,
        serverResults: ServerResultFetcher? = nil,
        queue: MutationQueue? = nil,
        exporter: MessageExporter? = nil,
        messageOpened: (@MainActor (_ messageId: Int64) async -> Void)? = nil
    ) {
        self.store = store
        self.client = client
        self.server = server
        self.prioritiser = prioritiser
        self.trustSender = trustSender
        self.serverResults = serverResults
        self.queue = queue
        self.exporter = exporter
        self.messageOpened = messageOpened
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
    /// PGP: the notice, and none of the body (ADR-0064).
    case encrypted
}

/// The header, assembled once per message rather than recomputed per redraw.
struct MessageHeader: Equatable {
    var messageId: Int64
    var remoteId: Int64
    var mailboxId: Int64
    var accountId: Int64
    var threadRootId: String?
    /// The `Message-ID` header, for the direct link.
    var messageIdHeader: String?
    var subject: String?
    var sender: Address?
    var to: [Address]
    var cc: [Address]
    var bcc: [Address] = []
    var sentAt: Date
    var isFlagged: Bool
    var isEncrypted: Bool
    var isImportant: Bool = false
    var isSeen: Bool = true
    var isMdnSent: Bool = false

    /// More than one person to answer, so the primary action is Reply all.
    var hasSeveralRecipients: Bool { to.count + cc.count > 1 }
}

/// Where a `serverResult` row is for one key: not asked, asked and not answered yet, or the
/// row's answer (ADR-0067).
enum ServerResultState<Value: Equatable>: Equatable {
    case idle
    case pending
    case ready(Value)
    case empty
    case failed

    var value: Value? {
        if case .ready(let value) = self { return value }
        return nil
    }
}

/// The message view's whole state, driven by the mirror.
///
/// One rule shapes every method here: nothing in this type ever reads a network response.
/// It reads the database, it asks for a body to be prioritised, it registers interest in a
/// server result, it queues, and it reads the database again when the database says it
/// changed.
///
/// Thread mode ([ADR-0085](../../../docs/decisions/0085-thread-mode-expands-one-message-at-a-time.md)):
/// `present(messageId:)` is the list's selection and starts the thread observation;
/// `expand(_:)` changes which one message of the thread is drawn without touching the
/// selection. Everything below `header` is about the expanded message.
@MainActor
@Observable
final class MessageViewModel {
    private(set) var header: MessageHeader?
    private(set) var presentation: MessageBodyPresentation = .waiting
    private(set) var attachments: [AttachmentRecord] = []
    /// The whole thread, oldest first. Empty for a message with no thread.
    private(set) var thread: [MessageRow] = []
    /// The message drawn in full, or nil when the reader collapsed it.
    private(set) var expandedId: Int64?
    private(set) var hasBlockedRemoteContent = false
    private(set) var isSenderTrusted = false
    private(set) var showsRemoteImages = false
    /// Phishing, S/MIME, PGP, read receipt, unsubscribe and AI content, from the body row.
    private(set) var security = MessageSecurityInfo.none
    /// The expanded message's tags, for the follow-up banner.
    private(set) var tags: [TagRecord] = []
    /// The expanded message's plain text, for the translation banner and sheet.
    private(set) var bodyText: String?
    /// The body has no plain part, so the server translates its HTML and the translation
    /// comes back as markup, to be shown as text.
    private(set) var translatesMarkup = false
    /// The reader's language's name when the on-device recogniser says the body is in
    /// another one: the translation banner. Detected once per body, not per redraw.
    private(set) var translationOfferLanguage: String?
    /// The instance's gates for the LLM features; nil until the login row is read.
    private(set) var login: LoginRecord?
    /// The expanded message's mailbox's special role, which hides smart replies in Trash
    /// and Junk.
    private(set) var mailboxRole: String?

    private(set) var smartReplies: ServerResultState<[String]> = .idle
    private(set) var threadSummary: ServerResultState<String> = .idle
    /// `true` once the follow-up check says somebody answered.
    private(set) var followUpAnswered = false
    private(set) var source: ServerResultState<String> = .idle
    private(set) var translation: ServerResultState<String> = .idle
    /// A queue write or export that failed, in a sentence for the pane. Cleared by the next
    /// action.
    var actionError: String?
    /// The outcome of an action, briefly, the way the web's toasts say it.
    var actionNotice: String?

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
    /// The observations, replaced rather than added to on every change. The body and the
    /// expanded message's results follow `expand`; the thread and the login follow
    /// `present`.
    private var bodyObservation: Task<Void, Never>?
    private var threadObservation: Task<Void, Never>?
    private var loginObservation: Task<Void, Never>?
    private var resultObservations: [String: Task<Void, Never>] = [:]
    private var bodyState: BodyState?
    private var loginId: Int64?

    init(services: MessageViewServices) {
        self.services = services
    }

    // MARK: - Selection

    /// Shows `messageId`, replacing whatever was being observed before.
    ///
    /// Replaced, not added to: dropping the task drops the iterator, which terminates the
    /// stream, which cancels the observation
    /// ([ADR-0034](../../../docs/decisions/0034-the-store-returns-its-own-sequence.md)).
    /// A new selection resets expansion: the selected message is the expanded one.
    func present(messageId newId: Int64?) {
        guard newId != messageId else { return }
        threadObservation?.cancel()
        threadObservation = nil
        messageId = newId
        thread = []
        threadSummary = .idle
        cancelResult(prefix: ServerResultKind.threadSummary.rawValue)
        show(newId)

        guard let newId else { return }
        threadObservation = Task { [weak self] in await self?.observeThread(messageId: newId) }
    }

    /// Expands `id` in place, collapsing the one that was. Expanding the expanded message
    /// collapses it, except in a conversation of one, which has nothing else to show.
    func toggle(_ id: Int64) {
        if id == expandedId {
            guard thread.count > 1 else { return }
            show(nil)
            return
        }
        show(id)
        if id != messageId, let opened = services.messageOpened {
            Task { await opened(id) }
        }
    }

    /// Everything about the expanded message, reset and observed again.
    private func show(_ id: Int64?) {
        bodyObservation?.cancel()
        bodyObservation = nil
        for key in Array(resultObservations.keys) where !key.hasPrefix(ServerResultKind.threadSummary.rawValue) {
            resultObservations.removeValue(forKey: key)?.cancel()
        }
        expandedId = id
        header = nil
        attachments = []
        hasBlockedRemoteContent = false
        isSenderTrusted = false
        showsRemoteImages = false
        security = .none
        tags = []
        bodyText = nil
        translatesMarkup = false
        translationOfferLanguage = nil
        bodyState = nil
        mailboxRole = nil
        smartReplies = .idle
        followUpAnswered = false
        source = .idle
        translation = .idle
        actionError = nil
        actionNotice = nil
        presentation = .waiting

        guard let id else { return }
        bodyObservation = Task { [weak self] in await self?.observe(messageId: id) }
    }

    /// The body, live.
    ///
    /// `MailStore.upsert(body:for:)` writes the body row, its attachments and
    /// `message.bodyState` in one transaction, so a value arrives here exactly when a
    /// backfilled body lands — and the view renders it without having asked the network for
    /// anything ([ADR-0038](../../../docs/decisions/0038-the-message-view-observes-the-thread.md)).
    private func observe(messageId: Int64) async {
        await refresh(messageId: messageId)
        await prioritiseIfNeeded(messageId: messageId)
        await resolveLogin(messageId: messageId)
        requestPerMessageResults()

        do {
            for try await stored in services.store.observeBody(messageId: messageId) {
                guard let stored, let header else { continue }
                attachments = stored.attachments
                isSenderTrusted = stored.body.isSenderTrusted
                bodyState = .present
                security = MessageSecurityInfo(
                    body: stored.body,
                    envelopeEncrypted: header.isEncrypted,
                    mdnSent: header.isMdnSent
                )
                bodyText = Self.readableText(of: stored.body)
                translatesMarkup = (stored.body.plainBody ?? "").isEmpty && stored.body.html != nil
                translationOfferLanguage = TranslationOffer.language(for: bodyText)
                if security.isPGP {
                    // ADR-0064: the honest notice, and nothing of the body at all.
                    presentation = .encrypted
                    hasBlockedRemoteContent = false
                    continue
                }
                await render(stored, header: header)
            }
        } catch {
            renderLog.error("body observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    /// The rest of the conversation, for the envelopes around the expanded message.
    ///
    /// It also carries what the body observation cannot see: `bodyState` and the flags live
    /// on `message`, and a fetch that gave up, a read receipt sent or a tag removed writes
    /// that table and no body row at all. A message with no `threadRootId` observes an empty
    /// thread, which still delivers — GRDB tracks the region the query reads rather than the
    /// rows it returns.
    private func observeThread(messageId: Int64) async {
        guard let record = try? await services.store.message(id: messageId) else { return }
        do {
            for try await rows in services.store.observeThread(
                rootId: record.threadRootId ?? "",
                mailboxId: record.mailboxId
            ) {
                thread = rows
                requestThreadSummary()
                guard let expandedId else { continue }
                await refresh(messageId: expandedId)
            }
        } catch {
            renderLog.error("thread observation stopped: \(RenderFailure.label(error), privacy: .public)")
        }
    }

    // MARK: - Reading the mirror

    /// The envelope: the header, its flags and tags, and what the body area says while there
    /// is no body.
    ///
    /// It deliberately does not render the body. That is ``observe(messageId:)``'s, and having
    /// one owner is what stops the same body being rendered twice when a message is opened.
    private func refresh(messageId: Int64) async {
        guard let record = try? await services.store.message(id: messageId), messageId == expandedId else { return }
        let addresses = (try? await services.store.addresses(messageId: messageId)) ?? []
        let tags = (try? await services.store.tags(messageId: messageId)) ?? []
        guard messageId == expandedId else { return }
        let header = Self.header(from: record, addresses: addresses)
        if header != self.header { self.header = header }
        if tags != self.tags { self.tags = tags }
        if security.readReceipt != nil {
            security.readReceipt = header.isMdnSent ? .sent : .requested
        }
        if mailboxRole == nil {
            mailboxRole = (try? await services.store.mailbox(id: record.mailboxId))?.specialRole
        }
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
            let header, !security.isPGP
        else { return }
        await render(stored, header: header)
    }

    private func render(_ stored: StoredBody, header: MessageHeader) async {
        let rendered = await Self.render(
            stored.body,
            header: header,
            server: services.server,
            showsRemoteImages: showsRemoteImages || isSenderTrusted
        )
        lastRewriteMilliseconds = rendered.milliseconds
        presentation = rendered.presentation
        if case .html(let document, _) = rendered.presentation {
            hasBlockedRemoteContent = document.hasBlockedRemoteContent
        } else {
            hasBlockedRemoteContent = false
        }
    }

    /// One body through the right renderer, off the main actor for HTML: a 5 MB body is a
    /// string walk long enough to drop frames, and everything the rewriter touches is a value
    /// type. Shared by the pane and the whole-thread printout, so paper gets the same pass.
    nonisolated static func render(
        _ body: MessageBodyRecord,
        header: MessageHeader,
        server: URL,
        showsRemoteImages: Bool
    ) async -> (presentation: MessageBodyPresentation, milliseconds: Double) {
        guard body.hasHtmlBody, let html = body.html, !html.isEmpty else {
            return (.plain(text: body.plainBody ?? "", signature: body.signature), 0)
        }
        let policy = MessageRenderPolicy(
            server: server,
            messageRemoteId: header.remoteId,
            showsRemoteImages: showsRemoteImages
        )
        let fontSize = MessageDocument.preferredBaseFontSize
        let started = ContinuousClock.now
        let rendered = await Task.detached(priority: .userInitiated) {
            MessageHTMLRewriter(policy: policy).render(fragment: html, baseFontSize: fontSize)
        }.value
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let context = MailAssetSchemeHandler.Context(
            localMessageId: header.messageId,
            remoteMessageId: header.remoteId,
            showsRemoteImages: policy.showsRemoteImages,
            inlineAttachmentIds: rendered.inlineAttachmentIds
        )
        return (.html(rendered, context), milliseconds)
    }

    /// The text a reader reads, for language detection and translation: the plain part, or
    /// the HTML reduced to text.
    nonisolated static func readableText(of body: MessageBodyRecord) -> String? {
        if let plain = body.plainBody, !plain.isEmpty { return plain }
        guard let html = body.html, !html.isEmpty else { return nil }
        let text = HTMLPlainText.text(of: html)
        return text.isEmpty ? nil : text
    }

    // MARK: - The network, in the places a view may touch it

    /// Raises this body's backfill priority. Writes the database; returns nothing.
    private func prioritiseIfNeeded(messageId: Int64) async {
        guard bodyState != .present, let prioritiser = services.prioritiser else { return }
        await prioritiser.prioritise(messageId: messageId)
    }

    /// The Retry the UX spec puts under a failed body.
    func retry() {
        guard let expandedId else { return }
        Task { await prioritiseIfNeeded(messageId: expandedId) }
    }

    // MARK: - Remote content

    /// Re-renders from the stored HTML with the block lifted. No request is made here: the
    /// WebView asks for `ncmail://asset/…` when it lays the document out, and the scheme
    /// handler decides again.
    func showImages() {
        guard !showsRemoteImages, let expandedId else { return }
        showsRemoteImages = true
        Task { await rerender(messageId: expandedId) }
    }

    /// Show images, and remember the sender, so the choice matches the web client.
    ///
    /// Through the offline queue rather than the client: the trust lands on every stored body
    /// from this sender in the same transaction as the queue row, so it holds offline and the
    /// body observation redraws with it. No request is awaited here.
    func alwaysShowFromThisSender() async {
        showImages()
        guard let email = header?.sender?.email, !email.isEmpty, let header else { return }
        await services.trustSender?(email, header.accountId)
    }

    /// The content rule list would not compile, so nothing was rendered.
    ///
    /// Fail closed. A body drawn without the layer that blocks every non-`ncmail:` load is
    /// not a body this app shows, however unlikely the failure is.
    func contentRuleListFailed(_ reason: String) {
        presentation = .blocked(reason)
    }

    // MARK: - Header

    /// The recipients come out of `messageAddress`, which is the table that holds them.
    static func header(from record: MessageRecord, addresses: [MessageAddressRecord]) -> MessageHeader {
        func list(_ kind: AddressKind) -> [Address] {
            addresses.filter { $0.kind == kind }.map { Address(label: $0.label, email: $0.email) }
        }
        return MessageHeader(
            messageId: record.id,
            remoteId: record.remoteId,
            mailboxId: record.mailboxId,
            accountId: record.accountId,
            threadRootId: record.threadRootId,
            messageIdHeader: record.messageId,
            subject: record.subject,
            sender: list(.from).first ?? Address(label: record.fromLabel, email: record.fromEmail),
            to: list(.to),
            cc: list(.cc),
            bcc: list(.bcc),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.sentAt)),
            isFlagged: record.isFlagged,
            isEncrypted: record.isEncrypted,
            isImportant: record.isImportant,
            isSeen: record.isSeen,
            isMdnSent: record.isMdnSent
        )
    }

    // MARK: - Observation plumbing for the extension

    /// The login the open message belongs to, observed for its LLM gates. Resolved once per
    /// pane: the pane is rebuilt for another account.
    private func resolveLogin(messageId: Int64) async {
        guard loginObservation == nil else { return }
        guard
            let record = try? await services.store.message(id: messageId),
            let account = try? await services.store.account(id: record.accountId)
        else { return }
        let identity = ServerIdentity(serverURL: account.serverURL, loginName: account.loginName)
        loginId = try? await services.store.login(for: identity)?.id
        loginObservation = Task { [weak self, store = services.store] in
            do {
                for try await login in store.observeLogin(for: identity) {
                    guard let self else { return }
                    self.login = login
                    if self.loginId == nil { self.loginId = login?.id }
                }
            } catch {
                renderLog.error("login observation stopped: \(RenderFailure.label(error), privacy: .public)")
            }
        }
    }

    /// Observes one `serverResult` row and hands each decoded payload to `apply`; asks the
    /// fetcher for it first. A second watch on the same `(kind, key)` replaces the first.
    func watch(
        _ kind: ServerResultKind,
        key: String,
        force: Bool = false,
        apply: @escaping @MainActor (MessageViewModel, ServerResultPayload?) -> Void
    ) {
        guard let loginId else { return }
        let id = "\(kind.rawValue)|\(key)"
        resultObservations.removeValue(forKey: id)?.cancel()
        let fetcher = services.serverResults
        resultObservations[id] = Task { [weak self, store = services.store] in
            await fetcher?.request(kind: kind, key: key, force: force)
            do {
                for try await row in store.observeServerResult(kind: kind.rawValue, key: key, loginId: loginId) {
                    guard let self else { return }
                    apply(self, row.flatMap { try? ServerResultPayload(payloadJSON: $0.payloadJSON) })
                }
            } catch {
                renderLog.error("server result observation stopped: \(RenderFailure.label(error), privacy: .public)")
            }
        }
    }

    private func cancelResult(prefix: String) {
        for key in Array(resultObservations.keys) where key.hasPrefix(prefix) {
            resultObservations.removeValue(forKey: key)?.cancel()
        }
    }

    /// Reads the expanded envelope again after this pane queued a change to it. The thread
    /// observation does not see every column — GRDB tracks the columns a query selects, and
    /// the list's row does not carry `$mdnsent` or the tags — so a write this pane made is
    /// re-read here rather than waited for.
    func reloadEnvelope() async {
        guard let expandedId else { return }
        await refresh(messageId: expandedId)
    }

    /// Setters for the extension, which cannot reach `private(set)` storage.
    func set(smartReplies value: ServerResultState<[String]>) { smartReplies = value }
    func set(threadSummary value: ServerResultState<String>) { threadSummary = value }
    func set(followUpAnswered value: Bool) { followUpAnswered = value }
    func set(source value: ServerResultState<String>) { source = value }
    func set(translation value: ServerResultState<String>) { translation = value }
    func markReadReceiptSent() { security.readReceipt = .sent }
    var resolvedLoginId: Int64? { loginId }
    var selectedId: Int64? { messageId }
}
