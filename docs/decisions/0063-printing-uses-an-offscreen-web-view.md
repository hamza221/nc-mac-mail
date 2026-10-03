<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0063: Printing builds its own offscreen web view, with the live view's configuration

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** wiring `⌘P`, which the menu bar offered and nothing implemented

## Context

`TriageContext.printMessage` existed and nothing set it, so Message ▸ Print Message was
always disabled. The UX spec lists `⌘P`.

Three facts shape how it can work:

- The menu bar cannot reach the message pane's `WKWebView`. `MessageBodyWebView` is an
  `NSViewRepresentable`, and SwiftUI builds and tears it down when it likes.
- A message has two renderers ([rendering.md](../architecture/rendering.md)). A plain body
  is SwiftUI `Text` with no web view at all.
- The header is native SwiftUI above the web view, so printing the live web view would
  print a body with no subject, no sender and no date.

## Decision

- The message pane registers what it is showing with `MessagePrintController`, one per
  `AppSession`. It registers the header and the presentation it has already drawn, and
  withdraws them when the pane goes away. A registration is tagged with the pane's view
  model, so a pane that disappears after its replacement appeared cannot clear the
  replacement's message.
- `⌘P` builds one HTML document. It is an escaped header block, followed by either the
  rewritten HTML document (the header goes straight after the shell's `<body>`) or the
  plain text, escaped inside a `pre-wrap` `<pre>` in the same shell.
- The document is loaded into a new offscreen `WKWebView`. It gets
  `MessageBodyWebView.configuration(serving:)`, the function the live view uses: JavaScript
  off, a non-persistent data store, and the `ncmail` scheme handler with the same
  `Context`. The content rule list is installed before the load. Every navigation except
  the initial `about:blank` is cancelled. The web view's appearance is forced to light,
  because paper is white.
- After `didFinish`, `printOperation(with: NSPrintInfo.shared)` runs modally for the key
  window. The job holds the web view until the print sheet's completion callback runs.
- `canPrint` is true only when a header and a drawn body (plain or HTML) are registered.
  The menu item reads it through `TriageContext.canPrintMessage`.

## Consequences

- Plain and HTML messages print the same way, with the same header, and both through the
  same protections as the screen.
- Paper shows exactly what the screen shows. A body that is still downloading, failed, or
  blocked by a rule-list failure cannot be printed. Remote images print only if the reader
  unblocked them.
- Each print starts a second WebContent process while the sheet is up, and loads inline
  images from the mirror again. Unblocked remote images are fetched again through the
  proxy, as ADR-0010 requires, because they are never stored.

## Alternatives considered

**Print the live web view.** No document is built, but there is no header. Plain bodies
have no web view to print. And the menu bar would need a handle on a view SwiftUI owns.

**Print the SwiftUI pane through `NSHostingView`.** This captures the header. But the
`WKWebView` inside a hosting view does not print its document through AppKit's view
printing, and the result would be one page clipped to the pane.

## Revisit when

macOS gives SwiftUI a print API that covers web content, or the message view starts
rendering the header inside the web document.
