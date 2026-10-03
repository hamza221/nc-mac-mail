// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Observation
import UniformTypeIdentifiers

/// The editor's model: an `NSTextStorage` the text view renders, plus everything the
/// toolbar needs to reflect and mutate it.
///
/// `@Observable` over the storage rather than a `String` binding because the document *is*
/// attributed text; HTML and plain text are serialisations taken at the edges
/// ([ADR-0065](../../docs/decisions/0065-native-rich-text-editor.md)). The document owns no
/// mail types and makes no network request — it is designed to be upstreamed.
@Observable
final class EditorDocument {

    enum Mode: Equatable {
        case plain
        case rich
    }

    /// Plain is undo/redo only; rich is the full §6.5 toolbar. Switch through
    /// ``enableFormatting()`` / ``disableFormatting()`` so the strip happens exactly once.
    private(set) var mode: Mode
    private(set) var selection = EditorSelectionState()
    /// The active `@` / `!` / `/` session, nil when none. The emoji session never appears
    /// here: the system palette is its UI ([ADR-0074](../../docs/decisions/0074-editor-triggers.md)).
    var trigger: TriggerSession?
    /// "The selected image is too large to embed", for the view to alert on.
    var imageError: String?

    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored let metrics: EditorFontMetrics
    @ObservationIgnored weak var textView: ComposerTextView?

    var baseFont: NSFont { metrics.baseFont }

    /// The web client refuses to embed images over 10 MB; parity keeps outgoing mail sane.
    static let maximumImageBytes = 10 * 1024 * 1024

    init(mode: Mode = .rich, baseFont: NSFont = EditorFontMetrics.defaultBaseFont) {
        self.mode = mode
        metrics = EditorFontMetrics(baseFont: baseFont)
    }

    // MARK: - Content in and out

    func html() -> String {
        HTMLSerializer.html(from: storage, baseFont: baseFont)
    }

    func plainText() -> String {
        PlainTextSerializer.text(from: storage)
    }

    func setHTML(_ html: String) {
        storage.setAttributedString(HTMLImporter.attributedString(fromHTML: html, baseFont: baseFont))
        textView?.undoManager?.removeAllActions()
        refreshSelectionState()
    }

    func setPlainText(_ text: String) {
        storage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes()))
        textView?.undoManager?.removeAllActions()
        refreshSelectionState()
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .editorBlock: EditorBlock.paragraph,
            .paragraphStyle: EditorPresentation.paragraphStyle(for: .paragraph, merging: nil),
        ]
    }

    // MARK: - Mode

    /// Anything "Turn off and remove formatting" would lose. The dialog only appears when
    /// this is true; an unformatted document switches silently.
    var hasFormatting: Bool {
        guard storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, stop in
            if let block = attrs[.editorBlock] as? EditorBlock, block != .paragraph { found = true }
            for key: NSAttributedString.Key in [
                .underlineStyle, .strikethroughStyle, .superscript, .link,
                .foregroundColor, .backgroundColor, .editorImage, .attachment,
            ] where attrs[key] != nil {
                found = true
            }
            if let font = attrs[.font] as? NSFont, font != baseFont { found = true }
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle,
                style.alignment != .natural || style.baseWritingDirection != .natural
            {
                found = true
            }
            if found { stop.pointee = true }
        }
        return found
    }

    func enableFormatting() {
        guard mode == .plain else { return }
        mode = .rich
        // The text is already plain; pin its attributes so the serialiser starts canonical.
        if storage.length > 0 {
            storage.setAttributes(baseAttributes(), range: NSRange(location: 0, length: storage.length))
        }
        refreshSelectionState()
    }

    /// The destructive half: the document collapses to its plain-text serialisation. The
    /// confirmation lives in the view; by the time this runs the user has answered.
    func disableFormatting() {
        guard mode == .rich else { return }
        mode = .plain
        setPlainText(plainText())
    }

    // MARK: - Inline formatting

    func toggleBold() { toggleTrait(.boldFontMask, isOn: selection.isBold, name: "Bold") }
    func toggleItalic() { toggleTrait(.italicFontMask, isOn: selection.isItalic, name: "Italic") }

    func toggleUnderline() {
        toggleFlag(.underlineStyle, isOn: selection.isUnderlined, name: "Underline")
    }

    func toggleStrikethrough() {
        toggleFlag(.strikethroughStyle, isOn: selection.isStruck, name: "Strikethrough")
    }

    func toggleSubscript() { setScript(selection.script == -1 ? 0 : -1) }
    func toggleSuperscript() { setScript(selection.script == 1 ? 0 : 1) }

    func setTextColor(_ color: NSColor?) { setValue(color, for: .foregroundColor, name: "Text Color") }
    func setBackgroundColor(_ color: NSColor?) { setValue(color, for: .backgroundColor, name: "Background Color") }

    func setFontFamily(_ family: String?) {
        mutateFonts(name: "Font") { font, expected in
            let target = family ?? expected.familyName ?? ""
            return NSFontManager.shared.convert(font, toFamily: target)
        }
    }

    func setFontSize(_ size: Int?) {
        mutateFonts(name: "Font Size") { font, expected in
            NSFontManager.shared.convert(font, toSize: size.map(CGFloat.init) ?? expected.pointSize)
        }
    }

    /// Applies `.link` to the selection; with nothing selected, inserts the URL as its own
    /// text, which is what every mail client does with a bare link.
    func applyLink(_ url: URL) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = typingAttributesForInsertion()
            attrs[.link] = url
            let link = NSAttributedString(string: url.absoluteString, attributes: attrs)
            textView.insertText(link, replacementRange: range)
        } else {
            editAttributes(in: range, name: "Add Link") { storage.addAttribute(.link, value: url, range: $0) }
        }
    }

    func removeLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        editAttributes(in: range, name: "Remove Link") { storage.removeAttribute(.link, range: $0) }
    }

    /// Strips inline formatting, keeps blocks — CKEditor's "Remove format".
    func removeFormatting() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        editAttributes(in: range, name: "Remove Formatting") { target in
            storage.enumerateAttributes(in: target) { attrs, runRange, _ in
                let block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
                var clean: [NSAttributedString.Key: Any] = [
                    .font: metrics.font(for: block),
                    .editorBlock: block,
                ]
                if let style = attrs[.paragraphStyle] { clean[.paragraphStyle] = style }
                if let image = attrs[.editorImage] { clean[.editorImage] = image }
                if let attachment = attrs[.attachment] { clean[.attachment] = attachment }
                storage.setAttributes(clean, range: runRange)
            }
        }
    }

    // MARK: - Blocks

    /// nil is "Paragraph" in the heading menu.
    func setHeading(_ level: Int?) {
        applyBlocks(name: "Heading") { block in
            var block = block
            block.kind = level.map { .heading($0) } ?? .paragraph
            return block
        }
    }

    func toggleList(_ kind: EditorListKind) {
        let on = selection.blockKind == .listItem(kind)
        applyBlocks(name: "List") { block in
            var block = block
            block.kind = on ? .paragraph : .listItem(kind)
            return block
        }
    }

    func toggleQuote() {
        let on = selection.isQuoted
        applyBlocks(name: "Block Quote") { block in
            var block = block
            block.isQuoted = !on
            return block
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        mutateParagraphStyles(name: "Alignment") { $0.alignment = alignment }
    }

    func setDirection(_ direction: NSWritingDirection) {
        mutateParagraphStyles(name: "Writing Direction") { $0.baseWritingDirection = direction }
    }

    // MARK: - Images

    /// The toolbar's Insert image: an open panel, the web client's formats and size limit,
    /// an embedded `data:` URL. No path here can fetch anything.
    func insertImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertImage(at: url)
    }

    func insertImage(at url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            imageError = "Could not insert the selected image."
            return
        }
        guard data.count <= Self.maximumImageBytes else {
            imageError = "The selected image is too large to embed."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        let mime = type.preferredMIMEType ?? "image/png"
        let src = "data:\(mime);base64,\(data.base64EncodedString())"
        guard let image = NSImage(data: data), image.size.width > 0 else {
            imageError = "Could not insert the selected image."
            return
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)
        let fragment = NSMutableAttributedString(attachment: attachment)
        var attrs = typingAttributesForInsertion()
        attrs[.editorImage] = EditorImage(src: src, width: Int(image.size.width))
        fragment.addAttributes(attrs, range: NSRange(location: 0, length: fragment.length))
        insertFragment(fragment)
    }

    // MARK: - Find and replace

    func showFindAndReplace() {
        // `performTextFinderAction` reads the action off the sender's tag; a menu item is
        // the smallest thing that has one.
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        textView?.performTextFinderAction(item)
    }

    // MARK: - Undo

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    // MARK: - Trigger insertion

    func insertMention(_ candidate: MentionCandidate) {
        guard let range = trigger?.range, let url = URL(string: "mailto:\(candidate.email)") else { return }
        trigger = nil
        var linkAttrs = typingAttributesForInsertion()
        linkAttrs[.link] = url
        let fragment = NSMutableAttributedString(string: "@\(candidate.displayName)", attributes: linkAttrs)
        fragment.append(NSAttributedString(string: " ", attributes: typingAttributesForInsertion()))
        insertFragment(fragment, replacing: range)
    }

    func insertTextBlock(_ block: EditorTextBlock) {
        guard let range = trigger?.range else { return }
        trigger = nil
        let fragment = HTMLImporter.attributedString(fromHTML: block.html, baseFont: baseFont)
        insertFragment(NSMutableAttributedString(attributedString: fragment), replacing: range)
    }

    func insertSmartPickerLink(_ link: SmartPickerLink) {
        guard let range = trigger?.range else { return }
        trigger = nil
        var linkAttrs = typingAttributesForInsertion()
        linkAttrs[.link] = link.url
        let fragment = NSMutableAttributedString(string: link.title, attributes: linkAttrs)
        fragment.append(NSAttributedString(string: " ", attributes: typingAttributesForInsertion()))
        insertFragment(fragment, replacing: range)
    }

    func cancelTrigger() {
        trigger = nil
    }

    // MARK: - Selection reflection

    func refreshSelectionState() {
        var state = EditorSelectionState()
        defer { if state != selection { selection = state } }
        guard let textView else { return }
        let range = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }

        if let font = attrs[.font] as? NSFont {
            let block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
            let expected = metrics.font(for: block)
            let traits = font.fontDescriptor.symbolicTraits
            state.isBold = traits.contains(.bold)
            state.isItalic = traits.contains(.italic)
            if let family = font.familyName, family != expected.familyName { state.fontFamily = family }
            if Int(font.pointSize.rounded()) != Int(expected.pointSize.rounded()) {
                state.fontSize = Int(font.pointSize.rounded())
            }
        }
        state.isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
        state.isStruck = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        state.script = attrs[.superscript] as? Int ?? 0
        state.hasLink = attrs[.link] != nil
        state.textColor = attrs[.foregroundColor] as? NSColor
        state.backgroundColor = attrs[.backgroundColor] as? NSColor
        let block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
        state.blockKind = block.kind
        state.isQuoted = block.isQuoted
        if let style = attrs[.paragraphStyle] as? NSParagraphStyle {
            state.alignment = style.alignment
            state.direction = style.baseWritingDirection
        }

        // A trigger session dies the moment the caret leaves it.
        if let trigger,
            !NSLocationInRange(
                range.location, NSRange(location: trigger.range.location, length: trigger.range.length + 1))
        {
            self.trigger = nil
        }
    }

    // MARK: - Shared edit plumbing

    private func selectedRange() -> NSRange {
        textView?.selectedRange() ?? NSRange(location: storage.length, length: 0)
    }

    private func typingAttributesForInsertion() -> [NSAttributedString.Key: Any] {
        var attrs = textView?.typingAttributes ?? baseAttributes()
        if attrs[.font] == nil { attrs[.font] = baseFont }
        if attrs[.editorBlock] == nil { attrs[.editorBlock] = EditorBlock.paragraph }
        return attrs
    }

    private func insertFragment(_ fragment: NSAttributedString, replacing range: NSRange? = nil) {
        guard let textView else { return }
        textView.insertText(fragment, replacementRange: range ?? textView.selectedRange())
        refreshSelectionState()
    }

    /// Attribute-only edit with its inverse registered: the before-image is captured, and
    /// because attribute edits never change length the range stays valid both ways.
    private func editAttributes(in range: NSRange, name: String, _ edit: (NSRange) -> Void) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        registerAttributeUndo(in: range, actionName: name)
        storage.beginEditing()
        edit(range)
        storage.endEditing()
        refreshSelectionState()
    }

    private func registerAttributeUndo(in range: NSRange, actionName: String) {
        guard let undoManager = textView?.undoManager else { return }
        let before = storage.attributedSubstring(from: range)
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.registerAttributeUndo(in: range, actionName: actionName)
                document.storage.replaceCharacters(in: range, with: before)
                document.refreshSelectionState()
            }
        }
        undoManager.setActionName(actionName)
    }

    private func toggleTrait(_ trait: NSFontTraitMask, isOn: Bool, name: String) {
        let manager = NSFontManager.shared
        mutateFonts(name: name) { font, _ in
            isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
    }

    private func toggleFlag(_ key: NSAttributedString.Key, isOn: Bool, name: String) {
        setValue(isOn ? nil : NSUnderlineStyle.single.rawValue, for: key, name: name)
    }

    private func setScript(_ script: Int) {
        setValue(script == 0 ? nil : script, for: .superscript, name: "Baseline")
    }

    private func setValue(_ value: Any?, for key: NSAttributedString.Key, name: String) {
        let range = selectedRange()
        if range.length > 0 {
            editAttributes(in: range, name: name) { target in
                if let value {
                    storage.addAttribute(key, value: value, range: target)
                } else {
                    storage.removeAttribute(key, range: target)
                }
            }
        } else if let textView {
            var attrs = textView.typingAttributes
            attrs[key] = value
            textView.typingAttributes = attrs
            refreshSelectionState()
        }
    }

    private func mutateFonts(name: String, _ transform: (NSFont, NSFont) -> NSFont) {
        let range = selectedRange()
        if range.length > 0 {
            editAttributes(in: range, name: name) { target in
                storage.enumerateAttributes(in: target) { attrs, runRange, _ in
                    let block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
                    let expected = metrics.font(for: block)
                    let font = attrs[.font] as? NSFont ?? expected
                    storage.addAttribute(.font, value: transform(font, expected), range: runRange)
                }
            }
        } else if let textView {
            var attrs = textView.typingAttributes
            let block = attrs[.editorBlock] as? EditorBlock ?? .paragraph
            let expected = metrics.font(for: block)
            let font = attrs[.font] as? NSFont ?? expected
            attrs[.font] = transform(font, expected)
            textView.typingAttributes = attrs
            refreshSelectionState()
        }
    }

    /// Alignment and direction live inside the paragraph style, per paragraph, preserving
    /// everything else the style carries.
    private func mutateParagraphStyles(name: String, _ change: (NSMutableParagraphStyle) -> Void) {
        guard let textView else { return }
        let string = storage.string as NSString
        let paragraphs = string.paragraphRange(for: textView.selectedRange())
        guard paragraphs.length > 0 else {
            var attrs = textView.typingAttributes
            let style = NSMutableParagraphStyle()
            if let existing = attrs[.paragraphStyle] as? NSParagraphStyle { style.setParagraphStyle(existing) }
            change(style)
            attrs[.paragraphStyle] = style
            textView.typingAttributes = attrs
            refreshSelectionState()
            return
        }
        editAttributes(in: paragraphs, name: name) { target in
            var location = target.location
            while location < NSMaxRange(target) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let style = NSMutableParagraphStyle()
                if let existing = storage.attributes(at: paragraph.location, effectiveRange: nil)[.paragraphStyle]
                    as? NSParagraphStyle
                {
                    style.setParagraphStyle(existing)
                }
                change(style)
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                location = NSMaxRange(paragraph)
            }
        }
    }

    /// Block edits run over whole paragraphs: identity, fonts and paragraph style move
    /// together so the storage never half-describes a block.
    private func applyBlocks(name: String, _ transform: (EditorBlock) -> EditorBlock) {
        guard let textView else { return }
        let string = storage.string as NSString
        let paragraphs = string.paragraphRange(for: textView.selectedRange())
        guard paragraphs.length > 0 else {
            // Caret in an empty document: the change applies to what gets typed next.
            var attrs = textView.typingAttributes
            let block = transform(attrs[.editorBlock] as? EditorBlock ?? .paragraph)
            attrs[.editorBlock] = block
            attrs[.font] = metrics.font(for: block)
            let existing = attrs[.paragraphStyle] as? NSParagraphStyle
            attrs[.paragraphStyle] = EditorPresentation.paragraphStyle(for: block, merging: existing)
            textView.typingAttributes = attrs
            refreshSelectionState()
            return
        }
        editAttributes(in: paragraphs, name: name) { target in
            var location = target.location
            while location < NSMaxRange(target) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let old = storage.attributes(at: paragraph.location, effectiveRange: nil)
                let block = transform(old[.editorBlock] as? EditorBlock ?? .paragraph)
                storage.addAttribute(.editorBlock, value: block, range: paragraph)
                let existing = old[.paragraphStyle] as? NSParagraphStyle
                let style = EditorPresentation.paragraphStyle(for: block, merging: existing)
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                storage.enumerateAttribute(.font, in: paragraph) { value, runRange, _ in
                    let font = value as? NSFont ?? baseFont
                    var updated = metrics.font(for: block)
                    if font.fontDescriptor.symbolicTraits.contains(.italic) {
                        updated = NSFontManager.shared.convert(updated, toHaveTrait: .italicFontMask)
                    }
                    storage.addAttribute(.font, value: updated, range: runRange)
                }
                location = NSMaxRange(paragraph)
            }
        }
    }
}

/// What the toolbar reflects about the caret or selection.
struct EditorSelectionState: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruck = false
    /// +1 sup, −1 sub.
    var script = 0
    var blockKind = EditorBlock.Kind.paragraph
    var isQuoted = false
    var alignment = NSTextAlignment.natural
    var direction = NSWritingDirection.natural
    /// nil means the default family/size for the block.
    var fontFamily: String?
    var fontSize: Int?
    var textColor: NSColor?
    var backgroundColor: NSColor?
    var hasLink = false
}
