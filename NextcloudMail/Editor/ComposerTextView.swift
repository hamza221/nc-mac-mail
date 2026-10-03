// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudPlatform
import UniformTypeIdentifiers

/// The TextKit 2 `NSTextView` under the composer.
///
/// Three jobs beyond being a text view, all of them security- or model-shaped:
///
/// - **Paste is restricted and routed.** The readable pasteboard types are plain text, RTF,
///   RTFD, images, HTML and file URLs — nothing else. HTML goes through ``HTMLImporter``
///   only, never AppKit's WebKit-backed HTML reading, so pasting cannot make a network
///   request. RTF is normalised to the attribute set the serialiser understands.
/// - **Files are attachments.** A pasted or dropped file — including a screenshot sitting
///   on the pasteboard as raw image data — is reported through ``onFileDrop`` and never
///   becomes inline content (§6.5).
/// - **Triggers.** `:`/`@`/`!`/`/` typed at a word boundary open a session
///   ([ADR-0074](../../docs/decisions/0074-editor-triggers.md)); this view detects, the
///   document publishes, the SwiftUI layer draws.
final class ComposerTextView: NSTextView {

    weak var document: EditorDocument?
    var onFileDrop: ((EditorDroppedFile) -> Void)?

    /// The TextKit 2 chain, built by hand because only the convenience factory — which
    /// cannot return a subclass — builds it for you.
    static func make(document: EditorDocument) -> ComposerTextView {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = document.storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: 1_000_000))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.document = document
        document.textView = view
        view.allowsUndo = true
        view.isRichText = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        // Graphics arrive as attachments through our own routing, never AppKit's.
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.isAutomaticLinkDetectionEnabled = false
        view.typingAttributes = document.baseAttributes()
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = CGSize(width: 8, height: 8)
        return view
    }

    // MARK: - Pasteboard restriction

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        guard document?.mode != .plain else { return [.string] }
        return [.fileURL, .png, .tiff, .html, .rtfd, .rtf, .string]
    }

    override func paste(_ sender: Any?) {
        readAllowedContent(from: NSPasteboard.general)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    /// The choke point the drag machinery also goes through. `.html` must never reach
    /// `super`: AppKit reads it with WebKit, which can fetch.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .html:
            guard let html = pboard.string(forType: .html) else { return false }
            insertImported(html: html)
            return true
        case .rtf:
            guard let data = pboard.data(forType: .rtf),
                let text = NSAttributedString(rtf: data, documentAttributes: nil)
            else { return false }
            insertNormalized(text)
            return true
        case .rtfd:
            guard let data = pboard.data(forType: .rtfd),
                let text = NSAttributedString(rtfd: data, documentAttributes: nil)
            else { return false }
            insertNormalized(text)
            return true
        case .png, .tiff:
            return reportImageData(on: pboard)
        case .fileURL:
            return reportFileURLs(on: pboard)
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    private func readAllowedContent(from pboard: NSPasteboard) {
        let types = pboard.types ?? []
        if document?.mode == .plain {
            if let text = pboard.string(forType: .string) {
                insertText(text, replacementRange: selectedRange())
            }
            return
        }
        // Files first, then raw images (a screenshot), then markup, then text: the order
        // decides what a multi-flavour pasteboard becomes.
        if types.contains(.fileURL), reportFileURLs(on: pboard) { return }
        if types.contains(.png) || types.contains(.tiff), reportImageData(on: pboard) { return }
        if types.contains(.html), readSelection(from: pboard, type: .html) { return }
        if types.contains(.rtfd), readSelection(from: pboard, type: .rtfd) { return }
        if types.contains(.rtf), readSelection(from: pboard, type: .rtf) { return }
        if let text = pboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    private func reportFileURLs(on pboard: NSPasteboard) -> Bool {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        for url in urls { onFileDrop?(.url(url)) }
        return true
    }

    private func reportImageData(on pboard: NSPasteboard) -> Bool {
        if let data = pboard.data(forType: .png) {
            onFileDrop?(.data(data, preferredName: "Pasted image.png"))
            return true
        }
        if let data = pboard.data(forType: .tiff) {
            onFileDrop?(.data(data, preferredName: "Pasted image.tiff"))
            return true
        }
        return false
    }

    private func insertImported(html: String) {
        guard let document else { return }
        let fragment = HTMLImporter.attributedString(fromHTML: html, baseFont: document.baseFont)
        insertText(fragment, replacementRange: selectedRange())
    }

    private func insertNormalized(_ text: NSAttributedString) {
        guard let document else { return }
        let normalized = PasteNormalizer.normalize(text, metrics: document.metrics) { [weak self] dropped in
            self?.onFileDrop?(dropped)
        }
        insertText(normalized, replacementRange: selectedRange())
    }

    // MARK: - Drops

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        let types = pboard.types ?? []
        if types.contains(.fileURL) { return reportFileURLs(on: pboard) }
        if types.contains(.png) || types.contains(.tiff) { return reportImageData(on: pboard) }
        // Markup and text drops land through readSelection(from:type:), which routes HTML
        // through the importer.
        return super.performDragOperation(sender)
    }

    // MARK: - Triggers

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let emojiTriggerLocation = pendingEmojiTriggerLocation
        super.insertText(string, replacementRange: replacementRange)
        guard let typed else { return }
        if let emojiTriggerLocation {
            consumeEmojiTrigger(at: emojiTriggerLocation, typed: typed)
            return
        }
        afterTyping(typed)
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        pendingEmojiTriggerLocation = nil
        guard let document, let session = document.trigger else { return }
        let caret = selectedRange().location
        if caret <= session.range.location {
            document.cancelTrigger()
        } else {
            updateSession(caret: caret)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        pendingEmojiTriggerLocation = nil
        if document?.trigger != nil {
            document?.cancelTrigger()
            return
        }
        super.cancelOperation(sender)
    }

    /// Where a just-typed `:` sits while the system palette is up. Not a full session: the
    /// palette is its own UI and the only question left is whether to remove the colon.
    private var pendingEmojiTriggerLocation: Int?

    private func afterTyping(_ typed: String) {
        guard let document else { return }
        let caret = selectedRange().location

        if document.trigger != nil {
            if typed.count == 1, let character = typed.first,
                character.isWhitespace || character.isNewline
            {
                document.cancelTrigger()
            } else {
                updateSession(caret: caret)
            }
            return
        }

        guard typed.count == 1, let character = typed.first,
            let kind = TriggerSession.Kind(rawValue: character),
            isWordBoundary(before: caret - 1)
        else { return }
        // Triggers that insert formatted results are rich-mode behaviour; the palette
        // inserts plain characters and works in both.
        if document.mode == .plain, kind != .emoji { return }

        if kind == .emoji {
            pendingEmojiTriggerLocation = caret - 1
            NCEmojiPalette.present()
            return
        }
        document.trigger = TriggerSession(
            kind: kind,
            range: NSRange(location: caret - 1, length: 1),
            query: "",
            caretRect: caretRectInScrollView())
    }

    private func updateSession(caret: Int) {
        guard let document, var session = document.trigger else { return }
        guard caret > session.range.location, let storage = textStorage else {
            document.cancelTrigger()
            return
        }
        let queryRange = NSRange(
            location: session.range.location + 1,
            length: caret - session.range.location - 1)
        guard NSMaxRange(queryRange) <= storage.length else {
            document.cancelTrigger()
            return
        }
        session.query = (storage.string as NSString).substring(with: queryRange)
        session.range = NSRange(location: session.range.location, length: caret - session.range.location)
        session.caretRect = caretRectInScrollView()
        document.trigger = session
    }

    /// The palette inserts at the caret. An emoji right after the trigger consumes the
    /// colon; anything else — including the Space the web client cancels on — keeps it.
    private func consumeEmojiTrigger(at location: Int, typed: String) {
        pendingEmojiTriggerLocation = nil
        // `isExtendedPictographic` is not surfaced by Swift; presentation-default emoji
        // plus the pictographic planes above U+238C is the standard approximation.
        guard let scalar = typed.unicodeScalars.first,
            scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
        else { return }
        let colonRange = NSRange(location: location, length: 1)
        guard let storage = textStorage, NSMaxRange(colonRange) <= storage.length,
            (storage.string as NSString).substring(with: colonRange) == ":",
            shouldChangeText(in: colonRange, replacementString: "")
        else { return }
        storage.replaceCharacters(in: colonRange, with: "")
        didChangeText()
    }

    private func isWordBoundary(before location: Int) -> Bool {
        guard location > 0 else { return true }
        guard let storage = textStorage, location <= storage.length else { return true }
        let previous = (storage.string as NSString).substring(with: NSRange(location: location - 1, length: 1))
        guard let character = previous.first else { return true }
        return character.isWhitespace || character.isNewline || character == "\u{2028}"
    }

    /// The caret rectangle in the enclosing scroll view's space, which is the coordinate
    /// space the SwiftUI popover overlays.
    private func caretRectInScrollView() -> CGRect {
        let caret = selectedRange()
        var rect = firstRect(forCharacterRange: NSRange(location: caret.location, length: 0), actualRange: nil)
        guard let window, let scrollView = enclosingScrollView else { return .zero }
        rect = window.convertFromScreen(rect)
        return scrollView.convert(rect, from: nil)
    }
}
