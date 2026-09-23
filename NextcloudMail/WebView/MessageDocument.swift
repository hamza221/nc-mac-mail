// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

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
        <body class="nc-mail-body">
        \(body)
        </body>
        </html>
        """
    }

    /// A reset, not a theme. Four things: the canvas, a readable default for mail that sets
    /// no font, images that cannot push the layout wider than the pane, and long unbroken
    /// strings — tracking ids, German compounds — that wrap instead of forcing a sideways
    /// scroll.
    private static func baseStyle(baseFontSize: Double, allowsOwnColorScheme: Bool) -> String {
        let canvas =
            allowsOwnColorScheme
            ? ":root { color-scheme: light dark; }"
            : ":root { color-scheme: light; } html, body { background: #ffffff; color: #1d1d1f; }"
        return """
            \(canvas)
            html, body { margin: 0; padding: 0; }
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
