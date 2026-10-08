// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// What the rewrite is allowed to let through for one message.
nonisolated struct MessageRenderPolicy: Equatable, Sendable {
    /// The signed-in server. Every URL a body may load resolves under it.
    var server: URL
    /// The server's id for this message. An attachment URL naming another message is refused,
    /// so one message cannot read another's parts (ADR-0033 — `remoteId` builds requests).
    var messageRemoteId: Int64
    /// False until the reader presses **Show images**, or the sender is trusted.
    var showsRemoteImages: Bool
}

/// The rewritten document, plus everything the chrome around it needs to know.
nonisolated struct RenderedMessage: Equatable, Sendable {
    /// The whole document, ready for `loadHTMLString`.
    var document: String
    /// At least one image the server replaced with its blocked placeholder.
    var hasBlockedRemoteContent: Bool
    /// How many remote images the document will ask for. Zero unless the reader unblocked.
    var remoteImagesShown: Int
    /// The attachment ids the document references, which is the set the scheme handler will
    /// serve and no other.
    var inlineAttachmentIds: Set<String>
    /// Elements removed whole, by name. Empty for every message the server sanitised
    /// properly, which is how a test tells a hostile document from an ordinary one.
    var droppedElements: [String]
    /// Attributes removed: event handlers, `javascript:` targets, images that resolve off
    /// the server.
    var removedAttributes: Int
    /// What each anchor's visible text said about where it goes, worked out during the
    /// rewrite because a cancelled navigation carries only a URL (ADR-0106).
    var links: LinkVerdicts
    /// The message says something about colour schemes, so it gets the real appearance
    /// rather than the forced light canvas (rendering.md).
    var prefersOwnColorScheme: Bool

    /// What to do with a click on `url`, the URL WebKit reports. The one question both of the
    /// web view's link callbacks ask.
    func verdict(for url: URL) -> LinkDisagreement.Verdict {
        links.verdict(for: url)
    }
}

/// Turns the stored sanitised fragment into the document the WebView loads.
///
/// Every image URL becomes `ncmail://asset/…` or disappears; there is no third outcome. That
/// is what makes the content rule list's "block everything except `ncmail:`" a statement
/// about the document rather than a hope about the network.
nonisolated struct MessageHTMLRewriter {
    let policy: MessageRenderPolicy

    /// Removed with their contents whatever the server left behind. The sanitiser takes all
    /// of these already; this is the second layer, and it costs one set lookup per tag.
    private static let forbiddenElements: Set<String> = [
        "script", "iframe", "object", "embed", "applet", "frame", "frameset",
        "form", "input", "button", "textarea", "select", "svg", "math", "video", "audio",
    ]

    /// Forbidden and void: there is no end tag to skip to, so only the tag itself goes.
    private static let forbiddenVoidElements: Set<String> = [
        "base", "link", "meta", "source", "track", "param", "input",
    ]

    /// Attributes whose value is a URL, wherever they appear.
    private static let urlAttributes: Set<String> = [
        "src", "href", "background", "poster", "action", "formaction", "cite", "data", "xlink:href",
    ]

    func render(fragment: String, baseFontSize: Double) -> RenderedMessage {
        var out = ""
        out.reserveCapacity(fragment.count + 2048)

        var result = RenderedMessage(
            document: "",
            hasBlockedRemoteContent: false,
            remoteImagesShown: 0,
            inlineAttachmentIds: [],
            droppedElements: [],
            removedAttributes: 0,
            links: LinkVerdicts(),
            prefersOwnColorScheme: Self.declaresColorScheme(fragment)
        )

        var skipping: (name: String, depth: Int)?
        var styleDepth = 0
        var anchorHref: String?
        var anchorText = AnchorText()
        // Every anchor is recorded, closed or not: a click on one that never was is answered
        // with a question (LinkVerdicts), which is right for a lie and wrong for an honest
        // link the server forgot to close.
        func finishAnchor() {
            if let href = anchorHref { result.links.record(text: anchorText.text, href: href) }
            anchorHref = nil
            anchorText = AnchorText()
        }

        var scanner = HTMLScanner(fragment)
        while let token = scanner.next() {
            if var skipped = skipping {
                switch token {
                case .startTag(let tag) where tag.name == skipped.name && !tag.isSelfClosing:
                    skipped.depth += 1
                    skipping = skipped
                case .endTag(let name) where name == skipped.name:
                    skipped.depth -= 1
                    skipping = skipped.depth > 0 ? skipped : nil
                default:
                    break
                }
                continue
            }

            switch token {
            case .text(let text):
                if styleDepth > 0 {
                    out += rewriteCSS(text, result: &result)
                } else {
                    if anchorHref != nil { anchorText.append(text) }
                    out += text
                }

            case .comment(let text):
                out += text

            case .startTag(var tag):
                if Self.forbiddenVoidElements.contains(tag.name) {
                    result.droppedElements.append(tag.name)
                    continue
                }
                if Self.forbiddenElements.contains(tag.name) {
                    result.droppedElements.append(tag.name)
                    if !tag.isSelfClosing { skipping = (tag.name, 1) }
                    continue
                }
                if tag.name == "style" { styleDepth += 1 }
                rewriteAttributes(of: &tag, result: &result)
                if tag.name == "a" {
                    finishAnchor()
                    anchorHref = tag.attributes.first { $0.name == "href" }?.value
                }
                out += Self.serialise(tag)

            case .endTag(let name):
                if name == "style" { styleDepth = max(0, styleDepth - 1) }
                if name == "a" { finishAnchor() }
                out += "</\(name)>"
            }
        }
        finishAnchor()

        result.document = MessageDocument.wrap(
            body: out,
            baseFontSize: baseFontSize,
            allowsOwnColorScheme: result.prefersOwnColorScheme
        )
        return result
    }

    /// The visible text of the anchor being read, as much of it as the link rule reads.
    ///
    /// Bounded as it is appended. A cap checked before an unbounded append bounded nothing:
    /// an anchor holding 100 KB of text and a run of `<br />`s copied that text once per
    /// line break. Runs of whitespace collapse to one space, as they do on screen, so markup
    /// indentation cannot use up the budget ahead of the words the reader sees, and entities
    /// are decoded, so `AT&amp;T` is what the confirmation quotes.
    private struct AnchorText {
        private(set) var text = ""
        private var bytes = 0
        private var pendingSpace = false

        mutating func append(_ raw: String) {
            guard bytes < LinkDisagreement.textLimit else { return }
            for scalar in HTMLEntities.decode(raw).unicodeScalars {
                if scalar.properties.isWhitespace {
                    pendingSpace = !text.isEmpty
                    continue
                }
                let width = UTF8.width(scalar) + (pendingSpace ? 1 : 0)
                guard bytes + width <= LinkDisagreement.textLimit else {
                    bytes = LinkDisagreement.textLimit
                    return
                }
                if pendingSpace {
                    text.unicodeScalars.append(" ")
                    pendingSpace = false
                }
                text.unicodeScalars.append(scalar)
                bytes += width
            }
        }
    }

    // MARK: - Attributes

    private func rewriteAttributes(of tag: inout HTMLStartTag, result: inout RenderedMessage) {
        var attributes: [HTMLAttribute] = []
        attributes.reserveCapacity(tag.attributes.count)

        // A blocked image is one the server replaced *and* left a restorable original on.
        // An original that resolves off the server is not restorable, so it is neither
        // counted as blocked content — the bar would promise something Show images cannot
        // deliver — nor carried into the document, inert or not.
        let original = tag.attributes.first { $0.name == "data-original-src" }?.value
        let blockedOriginal = original.flatMap { value -> String? in
            guard
                let absolute = URL(
                    string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: policy.server)?
                    .absoluteURL,
                MailAssetPolicy.classify(absolute, server: policy.server, messageRemoteId: policy.messageRemoteId)
                    == .proxiedRemoteImage
            else { return nil }
            return value
        }
        let originalStyle = tag.attributes.first { $0.name == "data-original-style" }?.value
        let isBlockedImage = tag.name == "img" && blockedOriginal != nil
        if isBlockedImage { result.hasBlockedRemoteContent = true }

        // What the image's `src` becomes, decided before the attribute loop so that a
        // blocked image with no `src` left still gets one when the reader unblocks.
        var replacementSource: String?
        if isBlockedImage, policy.showsRemoteImages, let blockedOriginal,
            let rewritten = assetURL(for: blockedOriginal, result: &result)
        {
            replacementSource = rewritten
        }

        for attribute in tag.attributes {
            let name = attribute.name

            if name.hasPrefix("on") {
                result.removedAttributes += 1
                continue
            }
            if name == "data-original-src", blockedOriginal == nil || policy.showsRemoteImages {
                // Either it points somewhere we would never load from, or it has just been
                // turned into the `src` above. Either way it is not wanted in the document.
                result.removedAttributes += 1
                continue
            }
            if tag.name == "img", original != nil, name == "src" {
                // The server's placeholder is a request for a picture of nothing.
                result.removedAttributes += 1
                continue
            }
            if name == "data-original-style" {
                // Never carried into the output. It is the saved copy of the author's style,
                // which is restored into `style` below when the reader unblocks, and an
                // inert copy of a declaration block otherwise.
                result.removedAttributes += 1
                continue
            }
            if isBlockedImage, name == "style" {
                // The sanitiser appended `display:none!important` to the author's style and
                // kept the original in `data-original-style`. Unblocking restores the
                // original; staying blocked keeps the hidden one.
                let value = policy.showsRemoteImages ? (originalStyle ?? attribute.value) : attribute.value
                attributes.append(
                    HTMLAttribute(name: "style", value: value.map { rewriteCSS($0, result: &result) })
                )
                continue
            }
            if name == "srcset" || name == "data-original-srcset" {
                if let value = attribute.value, let rewritten = rewriteSrcset(value, result: &result) {
                    attributes.append(HTMLAttribute(name: "srcset", value: rewritten))
                } else {
                    result.removedAttributes += 1
                }
                continue
            }
            if name == "style" {
                attributes.append(
                    HTMLAttribute(name: name, value: attribute.value.map { rewriteCSS($0, result: &result) })
                )
                continue
            }
            if name == "href", tag.name == "a" {
                if let value = attribute.value, Self.isClickable(value) {
                    attributes.append(attribute)
                } else {
                    result.removedAttributes += 1
                }
                continue
            }
            if Self.urlAttributes.contains(name) {
                if let value = attribute.value, let rewritten = assetURL(for: value, result: &result) {
                    attributes.append(HTMLAttribute(name: name, value: rewritten))
                } else {
                    result.removedAttributes += 1
                }
                continue
            }
            attributes.append(attribute)
        }

        if let replacementSource {
            attributes.append(HTMLAttribute(name: "src", value: replacementSource))
        }
        tag.attributes = attributes
    }

    /// `ncmail://asset/…` for a URL the policy allows, or nil for one it does not.
    ///
    /// The one value that passes through unchanged is a `data:` image, which is already in
    /// the document and asks the network for nothing.
    private func assetURL(for raw: String, result: inout RenderedMessage) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:image/"), !trimmed.lowercased().hasPrefix("data:image/svg") {
            return trimmed
        }
        guard let absolute = URL(string: trimmed, relativeTo: policy.server)?.absoluteURL,
            let kind = MailAssetPolicy.classify(
                absolute,
                server: policy.server,
                messageRemoteId: policy.messageRemoteId
            ),
            let rewritten = MailAssetURL.encode(absolute)
        else { return nil }

        switch kind {
        case .inlineAttachment(let attachmentId):
            result.inlineAttachmentIds.insert(attachmentId)
        case .proxiedRemoteImage:
            guard policy.showsRemoteImages else { return nil }
            result.remoteImagesShown += 1
        }
        return rewritten.absoluteString
    }

    /// Each candidate of a `srcset`, rewritten; nil when none of them survive.
    private func rewriteSrcset(_ value: String, result: inout RenderedMessage) -> String? {
        let candidates = value.split(separator: ",").compactMap { candidate -> String? in
            let parts = candidate.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let url = parts.first, let rewritten = assetURL(for: url, result: &result) else { return nil }
            return ([rewritten] + parts.dropFirst()).joined(separator: " ")
        }
        return candidates.isEmpty ? nil : candidates.joined(separator: ", ")
    }

    private static func isClickable(_ href: String) -> Bool {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else {
            // No scheme at all is a fragment or a relative path. Neither can navigate,
            // because the navigation delegate cancels everything after the first load.
            return !trimmed.lowercased().hasPrefix("javascript")
        }
        return MailLinkScheme.openable.contains(scheme)
    }

    // MARK: - CSS

    /// `@import` removed, every `url(…)` put through the same allowlist as an image.
    ///
    /// The `@import` matters: the recorded fixture's `<style>` block opens with
    /// `@import url(https://static-forms.klaviyo.com/…/custom_fonts.css)`, which is a remote
    /// host the message never shows and the server's sanitiser kept.
    func rewriteCSS(_ css: String, result: inout RenderedMessage) -> String {
        var out = removeImports(css, removed: &result.removedAttributes)
        guard out.lowercased().contains("url(") else { return out }

        var rebuilt = ""
        rebuilt.reserveCapacity(out.count)
        var index = out.startIndex
        while let open = out.range(of: "url(", options: [.caseInsensitive], range: index..<out.endIndex) {
            guard let close = out.range(of: ")", range: open.upperBound..<out.endIndex) else { break }
            rebuilt += out[index..<open.lowerBound]
            var inner = String(out[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if inner.count >= 2, let first = inner.first, first == "\"" || first == "'", inner.hasSuffix(String(first))
            {
                inner = String(inner.dropFirst().dropLast())
            }
            if let rewritten = assetURL(for: inner, result: &result) {
                let quoted = rewritten.replacingOccurrences(of: "\"", with: "%22")
                rebuilt += "url(\"" + quoted + "\")"
            } else {
                rebuilt += "none"
                result.removedAttributes += 1
            }
            index = close.upperBound
        }
        rebuilt += out[index..<out.endIndex]
        out = rebuilt
        return out
    }

    private func removeImports(_ css: String, removed: inout Int) -> String {
        guard css.lowercased().contains("@import") else { return css }
        var out = ""
        var index = css.startIndex
        while let start = css.range(of: "@import", options: [.caseInsensitive], range: index..<css.endIndex) {
            out += css[index..<start.lowerBound]
            let terminator = css.range(of: ";", range: start.upperBound..<css.endIndex)
            index = terminator?.upperBound ?? css.endIndex
            removed += 1
        }
        out += css[index..<css.endIndex]
        return out
    }

    // MARK: - Serialising

    private static func serialise(_ tag: HTMLStartTag) -> String {
        var out = "<" + tag.name
        for attribute in tag.attributes {
            out += " " + attribute.name
            if let value = attribute.value {
                out += "=\"" + HTMLEntities.escapeAttribute(value) + "\""
            }
        }
        out += tag.isSelfClosing ? " />" : ">"
        return out
    }

    /// True when the message has an opinion about dark mode, in which case it is given the
    /// real appearance instead of the forced light canvas.
    private static func declaresColorScheme(_ fragment: String) -> Bool {
        let lowered = fragment.lowercased()
        return lowered.contains("prefers-color-scheme") || lowered.contains("color-scheme:")
    }
}
