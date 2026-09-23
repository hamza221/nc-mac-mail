// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import NCMailNet
import NCMailStore
import SwiftUI
import WebKit

/// One click on a link in a message body, with the question already answered.
nonisolated struct MessageLinkActivation: Equatable, Identifiable {
    var url: URL
    var verdict: LinkDisagreement.Verdict

    var id: String { url.absoluteString }
}

/// The HTML body, in a `WKWebView` that can do nothing except draw it.
///
/// Everything that makes that true is in `makeNSView` and the coordinator below, and none of
/// it is optional: JavaScript off, no persistent data store, one scheme handler, a content
/// rule list that blocks every other load, and a navigation delegate that cancels every
/// navigation after the first.
///
/// The view is `@MainActor` because `WKWebView` is, and it stays that way: nothing here is
/// handed to an actor.
struct MessageBodyWebView: NSViewRepresentable {
    /// The rewritten document and everything learned while rewriting it.
    let rendered: RenderedMessage
    /// What the scheme handler may serve while this document is on screen.
    let assetContext: MailAssetSchemeHandler.Context
    let store: MailStore
    let client: MailClient
    let server: URL
    /// A link the reader clicked, with the confirmation verdict attached.
    let onLinkActivated: (MessageLinkActivation) -> Void
    /// The content rule list would not compile, so nothing was loaded. Fail closed: a body
    /// rendered without the third layer is not a body this app shows.
    let onBlocked: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            handler: MailAssetSchemeHandler(store: store, client: client, server: server),
            onLinkActivated: onLinkActivated,
            onBlocked: onBlocked
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Nothing a message does survives the view it was drawn in: no cookie, no local
        // storage, no cache shared with the next message.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: MailAssetURL.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // The public property. Never the `drawsBackground` KVC trick: it is private API and
        // a notarisation risk (rendering.md).
        webView.underPageBackgroundColor = .white
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // ⌘+ / ⌘− on the body, which ux-spec.md's accessibility section asks for.
        webView.allowsMagnification = true
        context.coordinator.attach(webView, rendered: rendered, assetContext: assetContext)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(rendered: rendered, assetContext: assetContext)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Navigation delegate, UI delegate, and the gate that keeps the first load from
    /// happening before the content rule list is installed.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let handler: MailAssetSchemeHandler
        private let onLinkActivated: (MessageLinkActivation) -> Void
        private let onBlocked: (String) -> Void

        private weak var webView: WKWebView?
        private var rendered: RenderedMessage?
        private var loadedDocument: String?
        private var ruleList: WKContentRuleList?
        private var installation: Task<Void, Never>?

        init(
            handler: MailAssetSchemeHandler,
            onLinkActivated: @escaping (MessageLinkActivation) -> Void,
            onBlocked: @escaping (String) -> Void
        ) {
            self.handler = handler
            self.onLinkActivated = onLinkActivated
            self.onBlocked = onBlocked
        }

        func attach(_ webView: WKWebView, rendered: RenderedMessage, assetContext: MailAssetSchemeHandler.Context) {
            self.webView = webView
            self.rendered = rendered
            handler.update(context: assetContext)
            installation = Task { [weak self] in
                do {
                    let list = try await MailContentRuleList.compiled()
                    guard let self, let webView = self.webView else { return }
                    webView.configuration.userContentController.add(list)
                    self.ruleList = list
                    self.loadIfNeeded()
                } catch {
                    renderLog.error("content rule list failed: \(RenderFailure.label(error), privacy: .public)")
                    self?.onBlocked(RenderFailure.label(error))
                }
            }
        }

        func detach() {
            installation?.cancel()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        func update(rendered: RenderedMessage, assetContext: MailAssetSchemeHandler.Context) {
            self.rendered = rendered
            // The handler is told what it may serve *before* the document that asks for it
            // is loaded, never after.
            handler.update(context: assetContext)
            loadIfNeeded()
        }

        /// Loads only once the rule list is installed, and only when the document actually
        /// changed — SwiftUI calls `updateNSView` for reasons that have nothing to do with
        /// the body, and reloading on each one would restart every image fetch.
        private func loadIfNeeded() {
            guard ruleList != nil, let webView, let rendered else { return }
            guard loadedDocument != rendered.document else { return }
            loadedDocument = rendered.document
            webView.loadHTMLString(rendered.document, baseURL: nil)
        }

        // MARK: - Navigation

        /// The async form of the policy callback, so the signature is WebKit's own and not a
        /// near-match the compiler rejects under strict concurrency.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            // `loadHTMLString(_:baseURL: nil)` navigates to `about:blank`. That is the only
            // navigation this view ever performs; everything else is the message trying to
            // go somewhere.
            if let scheme = url?.scheme?.lowercased(), scheme == "about" {
                return .allow
            }
            if let url, navigationAction.navigationType == .linkActivated, MailLinkScheme.isOpenable(url) {
                let text = rendered?.linkTexts[url.absoluteString]
                onLinkActivated(
                    MessageLinkActivation(url: url, verdict: LinkDisagreement.verdict(text: text, target: url))
                )
            }
            return .cancel
        }

        /// `target="_blank"` asks for a second web view. It does not get one.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated,
                MailLinkScheme.isOpenable(url)
            {
                let text = rendered?.linkTexts[url.absoluteString]
                onLinkActivated(
                    MessageLinkActivation(url: url, verdict: LinkDisagreement.verdict(text: text, target: url))
                )
            }
            return nil
        }
    }
}
