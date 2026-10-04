<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0085: Thread mode expands one message at a time, and whole-thread print is one document

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-30

## Context

The web client's thread view (§5.1 of the parity checklist) lists every message of a thread,
expands the selected one, and lets the reader expand any number of others; each expanded body
is an auto-resizing iframe, and in a multi-message thread each one "scrolls inside".

Two facts from [rendering.md](../architecture/rendering.md) constrain the native version:

- macOS `WKWebView` does not expose its scroll view, and JavaScript is off, so a body cannot
  be sized to its content. Every HTML body is a fixed frame that scrolls inside itself.
- Every `WKWebView` is a WebContent process, a content-rule-list installation and a scheme
  handler. v1 kept the count at one by showing only the selected message.

`⌘P` in the web client prints the whole thread, expanding collapsed messages first. The print
path ([ADR-0063](0063-printing-uses-an-offscreen-web-view.md)) is one offscreen web view with
one scheme-handler `Context`, and a `Context` names one message: an inline-attachment URL
naming any other message is refused.

## Decision

1. **One expanded message at a time.** The detail column lists the thread as collapsed
   envelopes with one expanded message between them. Clicking a collapsed envelope expands it
   and collapses the previous one; clicking the expanded header collapses it (not in a
   single-message thread). Expanding does not change the list selection. The expanded body
   takes the column's remaining height; the envelopes above and below it scroll inside
   capped bands.
2. **Whole-thread print is one document.** The printout is every message of the thread, each
   one's escaped header block followed by its body rewritten by its own
   `MessageHTMLRewriter` pass with its own policy, in one shell. Bodies are read from the
   mirror at print time, so collapsed messages print too.
3. **The scheme handler takes a list of contexts.** `MailAssetSchemeHandler.update(contexts:)`
   accepts one `Context` per message in the document. An inline-attachment URL is served only
   when its path names a message in the list *and* that message's own
   `inlineAttachmentIds` holds the id; it is served from that message's rows. A proxied
   remote image is served only when at least one listed message has remote images shown. The
   live view always passes exactly one context, so on screen nothing changes.

## Consequences

- Reading several messages of a thread side by side is not possible; the reader expands them
  in turn. The web's multi-expansion is a browser convenience whose cost here would be one
  WebContent process per expanded body, each in a fixed frame with its own scroll, nested in
  the column's scroll.
- The proxied-image check in a multi-message print document is weaker than on screen: the
  handler cannot attribute a proxy URL to a message (the URL's `id` parameter is the server's
  business, not a contract). It remains layered: the server rewrote every remote image to a
  blocked placeholder, and the rewriter of a message whose images are blocked emits no
  `ncmail://asset/` URL for them at all, so a blocked message's proxy URL never reaches the
  document the handler serves. Inline attachments keep the full per-message check.
- Security checkpoint 2 was walked for the handler change; the walk is in WS-30's report.

## Alternatives considered

- **Several expanded web views in a scroll view.** Rejected for the process count and the
  nested fixed-frame scrolling described above.
- **Print each message to a PDF and merge.** Keeps each body isolated with an unchanged
  handler, but needs one `NSPrintOperation` per message run to a file — the run-modal dance
  ADR-0063 needed once, N times — before the real print panel. Rejected as far more moving
  parts for a property (per-message proxy attribution) the rewriter already provides.
