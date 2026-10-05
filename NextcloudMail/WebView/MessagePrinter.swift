// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailCore
import NextcloudUI
import Observation
import WebKit

/// What the message pane has on screen, in the shape a printout needs.
///
/// Built from what the view model already rendered, never fetched: printing reads what the
/// database put on screen, and a body that is not on screen yet is not printable yet.
struct PrintableMessage: Equatable {
    enum Body: Equatable {
        case html(RenderedMessage, MailAssetSchemeHandler.Context)
        case plain(text: String, signature: String?)
        /// The header alone, with a line saying why: a body not mirrored yet in a whole-thread
        /// printout, or a PGP message, which prints its header and nothing else (ADR-0064).
        case headerOnly(note: String)

        /// Only a body that is actually drawn prints. Waiting and failed have nothing to put
        /// on paper, and a blocked body is one the protections refused to draw — printing it
        /// would route around the refusal.
        init?(_ presentation: MessageBodyPresentation) {
            switch presentation {
            case .html(let rendered, let context): self = .html(rendered, context)
            case .plain(let text, let signature): self = .plain(text: text, signature: signature)
            // A PGP message prints its header and the notice, as the web client prints it.
            case .encrypted: self = .headerOnly(note: MessagePGPNotice.text)
            case .waiting, .failed, .blocked: return nil
            }
        }
    }

    var header: MessageHeader
    var body: Body
}

/// `⌘P`: the one object the menu bar and the message pane share for printing.
///
/// The menu bar cannot reach the message pane's web view, and should not: that view is torn
/// down and rebuilt by SwiftUI whenever it likes, and a print sheet outlives a selection
/// change. So the pane registers what it is showing here, and printing builds its own
/// offscreen web view from that — with the live view's configuration, so paper gets exactly
/// the protections the screen does.
@MainActor
@Observable
final class MessagePrintController {
    /// The message the pane is showing, or nil when it shows no body.
    private(set) var current: PrintableMessage?
    /// The store, client and server the scheme handler serves images from. Not observed: it
    /// changes only with `current`.
    @ObservationIgnored private var services: MessageViewServices?
    /// Every message of the conversation the pane shows, collapsed ones included, read from
    /// the mirror when `⌘P` asks — the web client's `⌘P` prints the whole thread
    /// ([ADR-0085](../../docs/decisions/0085-thread-mode-expands-one-message-at-a-time.md)).
    /// Nil prints `current` alone.
    @ObservationIgnored private var thread: (@MainActor () async -> [PrintableMessage])?
    /// The view that registered `current`, so a pane that disappears after its replacement
    /// appeared cannot withdraw the replacement's message.
    @ObservationIgnored private var owner: ObjectIdentifier?
    /// The print in flight. Holding it is what keeps its web view alive until the sheet is
    /// dismissed; a second `⌘P` while it is up is ignored rather than stacked.
    private var job: MessagePrintJob?
    /// Between `⌘P` and the job existing, while the thread's bodies are read and rewritten.
    private var isPreparing = false

    var canPrint: Bool { current != nil && job == nil && !isPreparing }

    func show(
        _ message: PrintableMessage?,
        services: MessageViewServices,
        thread: (@MainActor () async -> [PrintableMessage])? = nil,
        from owner: AnyObject
    ) {
        current = message
        self.services = message == nil ? nil : services
        self.thread = message == nil ? nil : thread
        self.owner = ObjectIdentifier(owner)
    }

    func withdraw(from owner: AnyObject) {
        guard self.owner == ObjectIdentifier(owner) else { return }
        current = nil
        services = nil
        thread = nil
        self.owner = nil
    }

    /// `⌘P`: the whole conversation when the pane registered one, else the message on screen.
    func printCurrentMessage() {
        guard canPrint, let current, let services else { return }
        guard let thread else { return startJob([current], services: services) }
        isPreparing = true
        Task {
            let messages = await thread()
            isPreparing = false
            startJob(messages.isEmpty ? [current] : messages, services: services)
        }
    }

    /// The ⋯ menu's "Print message": one message, whichever is expanded.
    func printOnly(_ message: PrintableMessage, services: MessageViewServices) {
        guard job == nil, !isPreparing else { return }
        startJob([message], services: services)
    }

    private func startJob(_ messages: [PrintableMessage], services: MessageViewServices) {
        guard job == nil, let first = messages.first else { return }
        let contexts: [MailAssetSchemeHandler.Context] = messages.compactMap {
            // A plain or header-only document references nothing, so it adds nothing to serve.
            if case .html(_, let context) = $0.body { return context }
            return nil
        }
        let job = MessagePrintJob(
            document: messages.count == 1
                ? MessagePrintDocument.html(for: first) : MessagePrintDocument.html(forThread: messages),
            title: first.header.subject ?? String(localized: "No subject"),
            assets: contexts,
            services: services
        )
        self.job = job
        job.start { [weak self] in self?.job = nil }
    }
}

/// One print: an offscreen web view, the document, and the print sheet.
///
/// The configuration is ``MessageBodyWebView/configuration(serving:)``, the same one the
/// live view uses, and the content rule list is installed before the load, as it is there.
/// The navigation delegate is stricter than the live one: there is nobody to click a link
/// on paper, so every navigation but the initial `about:blank` is cancelled without being
/// offered to anyone.
@MainActor
final class MessagePrintJob: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    /// Held here as the live coordinator holds its own, rather than trusting the
    /// configuration's reference to outlive the load.
    private let handler: MailAssetSchemeHandler
    private let document: String
    private let title: String
    private var onFinish: (() -> Void)?
    private var installation: Task<Void, Never>?
    private var hasStartedPrinting = false

    init(
        document: String,
        title: String,
        assets: [MailAssetSchemeHandler.Context],
        services: MessageViewServices
    ) {
        let handler = MailAssetSchemeHandler(
            store: services.store,
            client: services.client,
            server: services.server
        )
        // Told what it may serve before the document that asks for it exists, as on screen.
        handler.update(contexts: assets)
        // A page-sized frame: a web view with a zero frame lays out to nothing, and the print
        // operation paginates whatever layout it is handed.
        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: NSPrintInfo.shared.paperSize),
            configuration: MessageBodyWebView.configuration(serving: handler)
        )
        webView.underPageBackgroundColor = .white
        // Paper is white. A message that opts into dark mode follows the appearance on
        // screen, and would otherwise print light text on a page with no dark background.
        webView.appearance = NSAppearance(named: .aqua)
        self.handler = handler
        self.webView = webView
        self.document = document
        self.title = title
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func start(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        installation = Task { [weak self] in
            do {
                let list = try await MailContentRuleList.compiled()
                guard let self, !Task.isCancelled else { return }
                self.webView.configuration.userContentController.add(list)
                self.webView.loadHTMLString(self.document, baseURL: nil)
            } catch {
                // Fail closed, as the live view does: no rule list, no load, no printout.
                renderLog.error("print: content rule list failed: \(RenderFailure.label(error), privacy: .public)")
                self?.finish()
            }
        }
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme?.lowercased() == "about" ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    /// `didFinish` is after the load event, which waits for the document's images — the
    /// inline attachments and unblocked images the scheme handler serves — so the printout
    /// has them.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        runPrintOperation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        renderLog.error("print: load failed: \(RenderFailure.label(error), privacy: .public)")
        finish()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        renderLog.error("print: load failed: \(RenderFailure.label(error), privacy: .public)")
        finish()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        renderLog.error("print: web content process terminated")
        finish()
    }

    // MARK: - Printing

    private func runPrintOperation() {
        guard !hasStartedPrinting else { return }
        hasStartedPrinting = true
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            renderLog.error("print: no window for the print sheet")
            return finish()
        }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // The print queue and the Save as PDF name, not a log.
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit hands back its printing view with a zero frame for a web view that was never
        // in a window, and `NSPrintOperation` refuses a zero-frame view.
        operation.view?.frame = webView.bounds
        // Modal for a window rather than `run()`: a WebKit print operation run synchronously
        // prints blank pages, because WebKit draws the pages asynchronously.
        operation.runModal(
            for: window,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        // Released on the next turn of the run loop rather than inside AppKit's callback,
        // which is still unwinding through the operation that draws from this web view.
        Task { self.finish() }
    }

    private func finish() {
        installation?.cancel()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?()
    }
}

/// The printable document: an escaped header block, then the body as it is drawn on screen.
///
/// Every header value is attacker-controlled — a subject or a display name is whatever the
/// sender typed — so each one is escaped before it touches markup.
enum MessagePrintDocument {
    static func html(for message: PrintableMessage) -> String {
        let header = headerBlock(message.header)
        switch message.body {
        case .html(let rendered, _):
            return inserting(header, into: rendered.document)
        case .plain(let text, let signature):
            var body = header + preformatted(text)
            if let signature, !signature.isEmpty {
                body += "<hr>" + preformatted(signature)
            }
            return MessageDocument.wrap(
                body: body,
                baseFontSize: MessageDocument.preferredBaseFontSize,
                allowsOwnColorScheme: false
            )
        case .headerOnly(let text):
            return MessageDocument.wrap(
                body: header + note(text),
                baseFontSize: MessageDocument.preferredBaseFontSize,
                allowsOwnColorScheme: false
            )
        }
    }

    /// Every message of a conversation in one document, oldest first: each one's escaped
    /// header, then its body as the rewriter drew it, a rule between messages.
    ///
    /// The HTML bodies are each the content of their own rewritten document — rewritten with
    /// that message's own policy, so a message whose images are blocked contributes no
    /// remote-image URL at all — placed in one light shell. Their `<style>` elements still
    /// apply document-wide, which is the cost of one web view rather than one per message
    /// (ADR-0085).
    static func html(forThread messages: [PrintableMessage]) -> String {
        let spacing = NCSpacingScale.macOS
        let separator = "<div style=\"margin: \(spacing.loose * 2)px 0; border-top: 2px solid;\"></div>"
        let sections = messages.map { message in
            let header = headerBlock(message.header)
            switch message.body {
            case .html(let rendered, _):
                return header + MessageDocument.bodyContent(of: rendered.document)
            case .plain(let text, let signature):
                var section = header + preformatted(text)
                if let signature, !signature.isEmpty { section += "<hr>" + preformatted(signature) }
                return section
            case .headerOnly(let text):
                return header + note(text)
            }
        }
        return MessageDocument.wrap(
            body: sections.joined(separator: separator),
            baseFontSize: MessageDocument.preferredBaseFontSize,
            allowsOwnColorScheme: false
        )
    }

    private static func note(_ text: String) -> String {
        "<p style=\"font-style: italic;\">\(escape(text))</p>"
    }

    /// Subject, sender, recipients and date — what the native header shows, which the web
    /// view never sees. Spacing is the library's scale read statically, as the document shell
    /// reads it; there is no environment here.
    static func headerBlock(_ header: MessageHeader) -> String {
        let spacing = NCSpacingScale.macOS
        var rows: [(label: String, value: String)] = []
        if let sender = header.sender {
            rows.append((label: String(localized: "From"), value: line(sender)))
        }
        if !header.to.isEmpty {
            rows.append((label: String(localized: "To"), value: header.to.map(line).joined(separator: ", ")))
        }
        if !header.cc.isEmpty {
            rows.append((label: String(localized: "Cc"), value: header.cc.map(line).joined(separator: ", ")))
        }
        rows.append(
            (label: String(localized: "Date"), value: header.sentAt.formatted(date: .long, time: .shortened))
        )

        let subject = header.subject ?? String(localized: "No subject")
        var html = """
            <div style="margin-bottom: \(spacing.loose)px; padding-bottom: \(spacing.standard)px; \
            border-bottom: 1px solid;">
            <div style="font-size: 1.4em; font-weight: 600; margin-bottom: \(spacing.standard)px;">\
            \(escape(subject))</div>
            """
        for row in rows {
            html += "<div><span style=\"font-weight: 600;\">\(escape(row.label)):</span> \(escape(row.value))</div>"
        }
        html += "</div>"
        return html
    }

    /// The header goes first inside the shell's `<body>`. The tag is always there: every
    /// `RenderedMessage` comes out of ``MessageDocument/wrap(body:baseFontSize:allowsOwnColorScheme:)``,
    /// and the first occurrence is the shell's own because everything before it is ours. The
    /// fallback prints the body alone rather than nothing.
    static func inserting(_ header: String, into document: String) -> String {
        guard let open = document.range(of: MessageDocument.bodyOpenTag) else { return document }
        var printable = document
        printable.insert(contentsOf: header, at: open.upperBound)
        return printable
    }

    /// Plain text as it reads on screen: the system font, wrapped, with the line breaks it
    /// was written with.
    private static func preformatted(_ text: String) -> String {
        "<pre style=\"white-space: pre-wrap; font: inherit; margin: 0;\">\(escape(text))</pre>"
    }

    /// Name and address both, because paper cannot be hovered to find out which address a
    /// display name stands for.
    private static func line(_ address: Address) -> String {
        guard
            let email = address.email, !email.isEmpty,
            let label = address.label, !label.isEmpty, label != email
        else { return address.displayName }
        return "\(label) <\(email)>"
    }

    /// Escaping for a quoted attribute escapes everything text content needs, and one
    /// escaper is one place to get it right.
    private static func escape(_ text: String) -> String {
        HTMLEntities.escapeAttribute(text)
    }
}
