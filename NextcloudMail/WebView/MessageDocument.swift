// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudUI

/// The document shell the server's `?plain=true` deliberately does not send.
///
/// The colours here are the message canvas, not app chrome, and they are deliberately not
/// theme tokens. [rendering.md](../../docs/architecture/rendering.md) is explicit: a message
/// that says nothing about colour schemes renders on a light canvas *always*, because HTML
/// written for a white background turns into black-on-grey when the appearance is forced
/// under it. The chrome around this document is SwiftUI and follows the system.
nonisolated enum MessageDocument {
    /// The reader's own body text size, so the message starts at the size the rest of macOS
    /// uses rather than at a number chosen here.
    static var preferredBaseFontSize: Double { Double(NSFont.systemFontSize) }

    /// The shell's opening `<body>`, named so the printout can put its header block right
    /// after it without re-parsing a document this file wrote.
    static let bodyOpenTag = "<body class=\"nc-mail-body\">"

    static func wrap(body: String, baseFontSize: Double, allowsOwnColorScheme: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(allowsOwnColorScheme ? "light dark" : "light")">
        <style>
        \(baseStyle(baseFontSize: baseFontSize, allowsOwnColorScheme: allowsOwnColorScheme))
        </style>
        </head>
        \(bodyOpenTag)
        \(body)
        </body>
        </html>
        """
    }

    /// What ``wrap(body:baseFontSize:allowsOwnColorScheme:)`` put between its own `<body>` and
    /// `</body>`, for a printout that places several messages in one shell.
    ///
    /// The first `bodyOpenTag` is the shell's because everything before it is ours, and the
    /// last `</body>` is the shell's because everything after it is ours; a fragment that
    /// carries a stray `</body>` of its own sits between the two and is kept, as on screen. A
    /// document this file did not write gives back nothing rather than its head.
    static func bodyContent(of document: String) -> String {
        guard
            let open = document.range(of: bodyOpenTag),
            let close = document.range(of: "</body>", options: .backwards),
            open.upperBound <= close.lowerBound
        else { return "" }
        return String(document[open.upperBound..<close.lowerBound])
    }

    /// A reset, not a theme. Five things: the canvas, a readable default for mail that sets
    /// no font, the same inset `PlainTextBodyView` gives a plain body, images that cannot push
    /// the layout wider than the pane, and long unbroken strings — tracking ids, German
    /// compounds — that wrap instead of forcing a sideways scroll.
    ///
    /// The inset is the library's `loose` token read statically, not `theme.metrics`: this
    /// builder runs off the main actor with no environment. Without it, the text-only HTML
    /// most personal mail arrives as (`<p>` and `<br>`, nothing else) ran into the pane's
    /// edges.
    private static func baseStyle(baseFontSize: Double, allowsOwnColorScheme: Bool) -> String {
        let canvas =
            allowsOwnColorScheme
            ? ":root { color-scheme: light dark; }"
            : ":root { color-scheme: light; } html, body { background: #ffffff; color: #1d1d1f; }"
        return """
            \(canvas)
            html, body { margin: 0; padding: 0; }
            body { padding: \(NCSpacingScale.macOS.loose)px; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              font-size: \(baseFontSize)px;
              line-height: 1.5;
              overflow-wrap: break-word;
            }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            pre { white-space: pre-wrap; }
            """
    }
}
