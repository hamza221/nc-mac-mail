<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-09 — Message view, WebView, scheme handler

**Wave 3, after WS-04. Size: XL. The unknowns live here.**

## Goal

Render a message safely: native header and chrome, HTML body in a locked-down `WKWebView`,
images served through our own scheme, and nothing that lets a message phone home.

## Before you start

- [../../architecture/rendering.md](../../architecture/rendering.md) — **all of it**
- [../../decisions/0009-sanitised-html-not-raw-mime.md](../../decisions/0009-sanitised-html-not-raw-mime.md)
- [../../decisions/0010-webview-scheme-handler.md](../../decisions/0010-webview-scheme-handler.md)
- [../../architecture/security.md](../../architecture/security.md) — you are review checkpoint 2
- [../../product/ux-spec.md](../../product/ux-spec.md) — message view section

## You own

`NextcloudMail/Views/Message/**`, `NextcloudMail/WebView/**`

## Build

**Two renderers.** Plain text (`hasHtmlBody == false`) renders in SwiftUI `Text`, selectable,
links detected — no web engine, no attack surface, and it covers most mail. HTML gets the
WebView. Decide per message.

**Header** — subject `.title2`; sender as `NCUserBubble`; recipients as `NCChip`, collapsed
past three; date; attachment chips. All native, all following the system appearance.

**`MessageBodyWebView`**, an `NSViewRepresentable`:

```swift
config.defaultWebpagePreferences.allowsContentJavaScript = false
config.websiteDataStore = .nonPersistent()
config.setURLSchemeHandler(MailAssetSchemeHandler(store: store, client: client), forURLScheme: "ncmail")
webView.underPageBackgroundColor = .white     // public API only; never the drawsBackground KVC trick
```

plus a `WKContentRuleList` blocking every load except `ncmail:`, and a navigation delegate
that cancels everything after the first load and opens links in the browser — with a
confirmation when the visible link text disagrees with the target host.

**HTML rewriting in Swift** (no JavaScript available): every image URL becomes
`ncmail://asset/{base64url(absolute URL)}`. Cover `src`, `data-original-src`, `srcset`,
`background`, and `url()` inside inline styles. Test against **recorded** fixtures — real
mail is stranger than anything you would invent — including a document that tries to escape
the rewrite.

**`MailAssetSchemeHandler`.** Decode, verify the URL belongs to the signed-in server, then:
inline attachments from `attachment.data` or fetch-and-store; proxied remote images fetched
only when unblocked for this message and **never stored**; everything else fails the load.
It is an allowlist. It runs on the main thread, so hand off immediately.

**Blocked-content bar** — `NCNoteCard(.warning)` with **Show images** and **Always show
from this sender**. Show images rewrites `data-original-src` back into `src`, restores
`data-original-style`, drops the injected `display:none!important`, reloads from stored
HTML. Always-show also calls `PUT /api/trustedsenders/{email}?type=individual`, so the
choice matches the web client. Detect blocked content once at store time, as a column, not
per render.

**Dark mode** — a message declaring `color-scheme` or using `prefers-color-scheme` gets the
real appearance; everything else renders on a light canvas, always. Forcing dark on HTML
written for white produces unreadable mail. Native chrome follows the system.

**Height** — default to the WebView scrolling in its own pane at a fixed frame. Prototype
the expanding variant too, check both against find-in-page, printing, selection across the
seam and a 200-message thread, then pick on evidence and write the reason into the
rendering document.

**Thread** — siblings below, collapsed, newest last, selected one expanded, expanding in
place rather than navigating.

**Attachments** — chips; click downloads via `NSSavePanel`; images preview in Quick Look.

**States** per the UX spec, and note the shape: the header is always available because the
envelope is always mirrored. The app never shows an empty screen where a message should be.

## Acceptance

- A message with remote images loads **nothing** until Show images. Verify with a proxy or
  Little Snitch, not by reading the code.
- A message with inline images renders them, and still renders them offline.
- A tracking pixel (under 5×5) stays blocked even after Show images — the server drops its
  URL, so there is nothing to restore.
- JavaScript in a message body does not execute. Test with a document that tries.
- Clicking a link opens the browser; a link whose text and target disagree asks first.
- The message cannot set a cookie or write local storage.
- Print, find-in-page and selection all work with the content rule list installed.
- Dark mode: native chrome dark, HTML mail readable, no grey-on-black.
- A 5 MB HTML message with 40 inline images renders without a memory spike — measure it.

## Out of scope

Triage buttons (WS-10). Itinerary cards, iMIP, S/MIME, PGP, smart replies, summaries — all
post-v1, and the data is already in `messageBody.rawJSON` when they arrive.

## Report

Additionally: the height decision and its evidence; every HTML-rewriting case real mail
threw at you; and a walk through
[../../architecture/security.md](../../architecture/security.md#review-checkpoints)
checkpoint 2, line by line, in the pull request body.
