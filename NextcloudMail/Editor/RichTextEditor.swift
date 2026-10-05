// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// ``ComposerTextView`` in a scroll view, bound to an ``EditorDocument``.
///
/// The representable is deliberately thin: the document owns the storage and the
/// formatting operations, the text view owns typing and pasting, and SwiftUI only ever
/// re-reads `document.mode`. Nothing here can trigger a network request — the view draws
/// the storage and the storage is filled by ``HTMLImporter`` or by typing.
struct RichTextEditor: NSViewRepresentable {
    let document: EditorDocument
    var onFileDrop: ((EditorDroppedFile) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView.make(document: document)
        textView.onFileDrop = onFileDrop
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.onFileDrop = onFileDrop
        let isRich = document.mode == .rich
        if textView.isRichText != isRich {
            textView.isRichText = isRich
            textView.typingAttributes = document.baseAttributes()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private weak var document: EditorDocument?

        init(document: EditorDocument) {
            self.document = document
        }

        func detach() {
            document?.textView = nil
            document = nil
        }

        func textDidChange(_ notification: Notification) {
            document?.refreshSelectionState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            document?.refreshSelectionState()
        }
    }
}
