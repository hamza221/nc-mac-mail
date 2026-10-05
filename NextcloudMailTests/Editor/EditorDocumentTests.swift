// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing

@testable import NextcloudMail

/// The document's formatting operations, the mode switch, the trigger sessions and the
/// pasteboard routing — everything with a branch in it that the fixed-point suite does not
/// already cover. The text view is real but windowless; nothing here draws.
@Suite("Editor document")
@MainActor
struct EditorDocumentTests {

    private static func makeEditor(html: String = "") -> (EditorDocument, ComposerTextView) {
        let document = EditorDocument()
        let view = ComposerTextView.make(document: document)
        if !html.isEmpty { document.setHTML(html) }
        return (document, view)
    }

    // MARK: - Formatting operations

    @Test("toggling bold over a selection serialises as strong, and toggles back off")
    func toggleBold() {
        let (document, view) = Self.makeEditor(html: "<p>hello</p>")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        document.refreshSelectionState()
        document.toggleBold()
        #expect(document.html() == "<p><strong>hello</strong></p>")
        #expect(document.selection.isBold)
        document.toggleBold()
        #expect(document.html() == "<p>hello</p>")
    }

    @Test("heading applies per paragraph and resets to the derived font")
    func heading() {
        let (document, view) = Self.makeEditor(html: "<p>title</p><p>body</p>")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        document.setHeading(1)
        #expect(document.html() == "<h1>title</h1><p>body</p>")
        document.setHeading(nil)
        #expect(document.html() == "<p>title</p><p>body</p>")
    }

    @Test("list and quote toggles are block toggles")
    func listAndQuote() {
        let (document, view) = Self.makeEditor(html: "<p>a</p><p>b</p>")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        document.toggleList(.unordered)
        #expect(document.html() == "<ul><li>a</li><li>b</li></ul>")
        document.refreshSelectionState()
        document.toggleList(.unordered)
        #expect(document.html() == "<p>a</p><p>b</p>")
        document.toggleQuote()
        #expect(document.html() == "<blockquote><p>a</p><p>b</p></blockquote>")
    }

    @Test("alignment and direction write the paragraph style")
    func alignmentAndDirection() {
        let (document, view) = Self.makeEditor(html: "<p>a</p>")
        view.setSelectedRange(NSRange(location: 0, length: 1))
        document.setAlignment(.center)
        document.setDirection(.rightToLeft)
        #expect(document.html() == "<p dir=\"rtl\" style=\"text-align:center\">a</p>")
    }

    @Test("remove formatting strips inline attributes and keeps the block")
    func removeFormatting() {
        let (document, view) = Self.makeEditor(
            html: "<h2><span style=\"color:#ff0000\"><strong><u>loud</u></strong></span></h2>")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        document.removeFormatting()
        #expect(document.html() == "<h2>loud</h2>")
    }

    @Test("a link applies to the selection and comes back off")
    func links() throws {
        let (document, view) = Self.makeEditor(html: "<p>docs</p>")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        let url = try #require(URL(string: "https://example.com"))
        document.applyLink(url)
        #expect(document.html() == "<p><a href=\"https://example.com\">docs</a></p>")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        document.removeLink()
        #expect(document.html() == "<p>docs</p>")
    }

    // MARK: - Modes

    @Test("hasFormatting sees blocks, inline attributes and nothing else")
    func hasFormatting() {
        let (plainDocument, _) = Self.makeEditor(html: "<p>plain text</p>")
        #expect(!plainDocument.hasFormatting)
        let (richDocument, _) = Self.makeEditor(html: "<p><strong>rich</strong></p>")
        #expect(richDocument.hasFormatting)
        let (headed, _) = Self.makeEditor(html: "<h1>rich</h1>")
        #expect(headed.hasFormatting)
    }

    @Test("disabling formatting collapses to the plain serialisation; enabling keeps text")
    func modeSwitch() {
        let (document, _) = Self.makeEditor(html: "<h1>t</h1><ul><li>a</li></ul>")
        document.disableFormatting()
        #expect(document.mode == .plain)
        #expect(document.storage.string == "t\n- a")
        #expect(!document.hasFormatting)
        document.enableFormatting()
        #expect(document.mode == .rich)
        #expect(document.storage.string == "t\n- a")
        #expect(document.html() == "<p>t</p><p>- a</p>")
    }

    // MARK: - Triggers

    @Test("@ at a word boundary opens a session; the query follows the caret")
    func mentionSession() throws {
        let (document, view) = Self.makeEditor()
        view.insertText("hi ", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("@", replacementRange: view.selectedRange())
        let opened = try #require(document.trigger)
        #expect(opened.kind == .mention)
        #expect(opened.query.isEmpty)
        view.insertText("lo", replacementRange: view.selectedRange())
        #expect(document.trigger?.query == "lo")
    }

    @Test("mid-word trigger characters stay plain text")
    func midWordNoSession() {
        let (document, view) = Self.makeEditor()
        view.insertText("mail", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("@", replacementRange: view.selectedRange())
        #expect(document.trigger == nil)
        view.insertText("https:", replacementRange: view.selectedRange())
        view.insertText("/", replacementRange: view.selectedRange())
        #expect(document.trigger == nil)
    }

    @Test("space cancels, deleting past the trigger cancels")
    func sessionCancels() {
        let (document, view) = Self.makeEditor()
        view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        #expect(document.trigger != nil)
        view.insertText(" ", replacementRange: view.selectedRange())
        #expect(document.trigger == nil)

        // After the cancelling space the caret sits at a boundary again, so a fresh
        // trigger opens a fresh session.
        view.insertText("/", replacementRange: view.selectedRange())
        #expect(document.trigger?.kind == .smartPicker)
    }

    @Test("deleting the trigger character ends the session")
    func deleteCancels() {
        let (document, view) = Self.makeEditor()
        view.insertText("@", replacementRange: NSRange(location: 0, length: 0))
        #expect(document.trigger != nil)
        view.deleteBackward(nil)
        #expect(document.trigger == nil)
    }

    @Test("an accepted mention replaces the session with a mailto link")
    func mentionInsert() {
        let (document, view) = Self.makeEditor()
        view.insertText("@", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("lor", replacementRange: view.selectedRange())
        document.insertMention(MentionCandidate(displayName: "Lorelai", email: "lorelai@dragonfly.example"))
        #expect(document.trigger == nil)
        #expect(document.html() == "<p><a href=\"mailto:lorelai@dragonfly.example\">@Lorelai</a> </p>")
    }

    @Test("an accepted text block imports through the importer")
    func textBlockInsert() {
        let (document, view) = Self.makeEditor()
        view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        document.insertTextBlock(EditorTextBlock(title: "Greeting", html: "<p><strong>Hi</strong></p>"))
        #expect(document.html() == "<p><strong>Hi</strong></p>")
    }

    // MARK: - Pasteboard routing

    private static func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ncmail-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        fill(pasteboard)
        return pasteboard
    }

    @Test("pasted HTML goes through the importer, so a remote image cannot arrive")
    func htmlPaste() {
        let (document, view) = Self.makeEditor()
        let pasteboard = Self.pasteboard {
            $0.setString(
                "<p><b>bold</b><img src=\"https://evil.example/t.png\"></p>", forType: .html)
        }
        defer { pasteboard.releaseGlobally() }
        #expect(view.readSelection(from: pasteboard, type: .html))
        #expect(document.html() == "<p><strong>bold</strong></p>")
    }

    @Test("a pasted file URL becomes an attachment callback, never content")
    func filePaste() throws {
        let (document, view) = Self.makeEditor()
        var dropped: [EditorDroppedFile] = []
        view.onFileDrop = { dropped.append($0) }
        // A real file inside the container: the host is sandboxed, so a file URL outside it
        // (or one that does not exist) makes the pasteboard server fail to mint a sandbox
        // extension for `public.file-url`, and that synchronous IPC can stall the main actor.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncmail-paste-\(UUID().uuidString)")
            .appendingPathComponent("menu.pdf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pasteboard = Self.pasteboard { $0.writeObjects([file as NSURL]) }
        defer { pasteboard.releaseGlobally() }
        #expect(view.readSelection(from: pasteboard, type: .fileURL))
        #expect(document.storage.length == 0)
        #expect(dropped.count == 1)
        guard case .url(let url) = try #require(dropped.first) else {
            Issue.record("expected a file URL")
            return
        }
        #expect(url.lastPathComponent == "menu.pdf")
    }

    @Test("pasted image data becomes an attachment callback")
    func imageDataPaste() throws {
        let (document, view) = Self.makeEditor()
        var dropped: [EditorDroppedFile] = []
        view.onFileDrop = { dropped.append($0) }
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let pasteboard = Self.pasteboard { $0.setData(png, forType: .png) }
        defer { pasteboard.releaseGlobally() }
        #expect(view.readSelection(from: pasteboard, type: .png))
        #expect(document.storage.length == 0)
        #expect(dropped.count == 1)
    }

    @Test("in plain mode only plain text is readable")
    func plainModeTypes() {
        let (document, view) = Self.makeEditor()
        document.disableFormatting()
        #expect(view.readablePasteboardTypes == [.string])
        document.enableFormatting()
        #expect(view.readablePasteboardTypes.contains(.html))
        #expect(!view.readablePasteboardTypes.contains(NSPasteboard.PasteboardType("com.apple.webarchive")))
    }

    @Test("pasted RTF is normalised to the attribute set the serialiser can express")
    func rtfPaste() throws {
        // Georgia rather than the system font: RTF rewrites the system family name, and
        // this test is about attribute filtering, not font substitution.
        var bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toFamily: "Georgia")
        bold = NSFontManager.shared.convert(bold, toHaveTrait: .boldFontMask)
        let source = NSMutableAttributedString(
            string: "styled",
            attributes: [.font: bold, .kern: 4, .shadow: NSShadow()])
        let data = try #require(
            source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]))
        let (document, view) = Self.makeEditor()
        let pasteboard = Self.pasteboard { $0.setData(data, forType: .rtf) }
        defer { pasteboard.releaseGlobally() }
        #expect(view.readSelection(from: pasteboard, type: .rtf))
        #expect(document.html() == "<p><span style=\"font-family:Georgia\"><strong>styled</strong></span></p>")
    }
}
