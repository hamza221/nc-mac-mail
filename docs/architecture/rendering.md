<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Rendering message bodies

*The most security-sensitive surface in the app, and the one place where a mirror changes
the rules. Owned by WS-09.*

## Two renderers, not one

| Body | Renderer | Why |
| --- | --- | --- |
| Plain text (`hasHtmlBody == false`) | SwiftUI `Text`, selectable, with linkified URLs | No web engine, no security surface, native selection and Dynamic Type. Most mailing-list and notification mail lands here |
| HTML | `WKWebView` behind `MessageBodyWebView` | Nothing else renders real-world HTML mail |

Deciding per message keeps the expensive, dangerous path off the majority of messages. The
plain body is already in `messageBody.plainBody` from the mirror.

## What the mirror stores

`messageBody.html` is the **sanitised fragment** from
`GET /api/messages/{id}/html?plain=true` — HTMLPurifier output, no `<html>` wrapper, no
iframe-resizer script ([ADR-0009](../decisions/0009-sanitised-html-not-raw-mime.md)).

The server has already done the dangerous part, and one of its transformations shapes
everything below. `lib/Service/HtmlPurify/TransformImageSrc.php` rewrites every remote
image before we ever see it:

```html
<!-- what the message contained -->
<img src="https://tracker.example/pixel.gif?u=123" width="1" height="1">

<!-- what we receive -->
<img src="/apps/mail/img/blocked-image.png"
     data-original-src="https://cloud.example/index.php/apps/mail/proxy?src=…&id=…&hmac=…"
     data-original-style="…"
     style="…;display:none!important">
```

Three consequences:

1. **Remote content is blocked before it reaches disk.** The backfill can mirror 40,000
   messages without fetching a single tracking pixel. That is a genuine privacy property
   the web client cannot have, and it comes free.
2. **"Show images" is a DOM edit**, not a reload. The web client does it in JavaScript. We
   do it in Swift, because our JavaScript is off.
3. **Sanitisation happened at mirror time, not at read time.** If the server's purifier
   improves, stored HTML is stale — hence `messageBody.sanitiserGeneration` and the
   re-download control in [local-mirror.md](local-mirror.md).

**And one thing the transformation does not cover.** `TransformImageSrc` rewrites `<img>`.
It does not touch CSS, and HTMLPurifier keeps `<style>`. The recorded body
(`message-html-plain.html`) opens with

```css
@import url(https://static-forms.klaviyo.com/fonts/api/v1/U45QAK/custom_fonts.css);
```

which is a fourth remote host, unblocked, in a message whose images are all blocked. WS-09
found it while rewriting and deletes every `@import` and every refused `url(…)`
([ADR-0039](../decisions/0039-a-rendered-message-holds-only-urls-we-would-fetch.md)). The
claim "the backfill can mirror 40,000 messages without fetching a single tracking pixel"
stays true — nothing fetches CSS at mirror time — but "remote content is blocked before it
reaches disk" is true of images and not of stylesheets. It is filed in
[../feedback/server-findings.md](../feedback/server-findings.md).

## The WebView

```swift
config.defaultWebpagePreferences.allowsContentJavaScript = false
config.setURLSchemeHandler(MailAssetSchemeHandler(store:client:), forURLScheme: "ncmail")
config.websiteDataStore = .nonPersistent()
webView.underPageBackgroundColor = .white            // public API; never the
                                                     // `drawsBackground` KVC trick,
                                                     // which is private and a
                                                     // notarization risk
```

Plus, and none of these are optional:

- **A `WKContentRuleList` blocking every load except `ncmail:`.** JavaScript is off and the
  server already neutralised remote images, so this is the third layer. Layers are the
  point: one server-side bug should not become an IP leak.
- **A navigation delegate that cancels everything.** The first `loadHTMLString` is the only
  navigation. A link click is cancelled and handed to `openURL` — after a confirmation when
  the visible link text disagrees with the target host, which is the cheapest anti-phishing
  control there is and one the web client has a whole detector for.

  The visible text has to be collected during the rewrite, because a cancelled navigation
  carries a URL and nothing else: by the time WebKit asks, the anchor is gone. Where two
  anchors share one `href` and say different things, the text that *names a host* is the one
  kept — it is the one the rule can act on. Text that claims no host at all ("Shop now",
  "Hoodies") asks no question, which is why the recorded body's thirteen click-tracker links
  produce no confirmations. A rule that asks about every marketing link is a rule people
  click through.
- **No persistent data store.** A message must not be able to set a cookie or fill local
  storage.

## Images, and why they need a custom scheme

Both kinds of image in a Nextcloud mail body live behind an authenticated endpoint:

| Image | URL in the sanitised HTML | Needs |
| --- | --- | --- |
| Inline attachment (`cid:`) | `…/apps/mail/api/messages/{id}/attachment/{aid}` | Basic auth |
| Remote, when unblocked | `…/apps/mail/proxy?src=…&id=…&hmac=…` | Basic auth |

`WKWebView` will not attach our `Authorization` header to subresource loads, and giving it
a session cookie is exactly what [networking.md](networking.md) forbids. So every image URL
is rewritten to a custom scheme and served by us:

```
ncmail://asset/{base64url(original URL)}
```

`MailAssetSchemeHandler` decodes it, checks it is a URL on the signed-in server, and:

- **inline attachment** → serve from the `attachment.data` blob if present, otherwise fetch
  through `MailClient`, store it, serve it. Offline, an already-read message keeps its
  pictures.
- **proxied remote image** → fetch through `MailClient` only if remote content is unblocked
  for this message. Never stored ([ADR-0010](../decisions/0010-webview-scheme-handler.md)):
  storing it would give a tracking pixel a permanent home on the user's disk for no gain.
  The response's `Content-Type` is no help: `ProxyController::proxy` sends
  `application/octet-stream` for every image. The handler takes the type from the bytes'
  signature (`ImageSignature`, raster formats only) and refuses anything that does not
  match. Until 2026-10-03 it trusted the header, so no remote image ever loaded.
- **anything else** → fail the load. The handler is an allowlist, not a proxy.

The allowlist is one function, `MailAssetPolicy.classify(_:server:messageRemoteId:)`, and
both the rewriter and the handler call it: the rewriter to decide what a URL in the stored
HTML may become, the handler to decide what the WebView may actually have. A rewriting bug
therefore cannot widen what the handler serves. It also refuses an attachment URL naming a
different message, so one message cannot read another's parts.

Inline attachments are served **out of the database in every path**. On a miss the handler
fetches, writes `attachment.data`, and then reads the row back to answer the load, rather
than handing the response's bytes to the WebView. Proxied remote images are the one
exception, and it is ADR-0010's: they are never stored, so there is nothing to read back.

`data:` URIs were the alternative and were rejected: a 4 MB inline image becomes a 5.5 MB
base64 string in an HTML document held in memory, per message, and the WebView re-parses it
on every layout.

## The document shell

We build the document the server's `plain=true` deliberately does not:

```html
<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>/* reset, typography from the theme, and the dark-mode rules below */</style>
</head><body class="nc-mail-body">…fragment…</body></html>
```

**Dark mode** is the part everyone gets wrong. Rules:

- A message that declares `color-scheme: dark light` or uses `prefers-color-scheme` gets
  the real appearance.
- Everything else renders on a **light canvas**, always, even in dark mode. Forcing dark on
  HTML written for white backgrounds produces black text on dark grey and unreadable
  logos. Apple Mail does the same thing for the same reason.
- The chrome around the body — header, toolbar, attachment row — is native SwiftUI and
  follows the system appearance. The seam between them is a visible edge, which is honest:
  it marks where the message starts.
- Plain-text bodies are native, so they follow dark mode properly. That covers most mail.

**Height.** The server's resizer script reports the body height to the browser, and the
web client sizes its iframe from that. We have neither the script nor JavaScript to run
it, so the default is the simpler shape: **the WebView scrolls in its own pane at a fixed
frame**, with the native header above it, rather than expanding to its content height
inside a SwiftUI `ScrollView`.

The expanding variant is nicer — one scroll surface for header and body together — and it
needs a content height.

**WS-09 kept the fixed frame, and did not prototype the expanding variant.** The reason is
not preference, it is that the expanding variant has no supported implementation here:

- On iOS the content height is `webView.scrollView.contentSize`, which is public. **macOS
  `WKWebView` does not expose its scroll view at all.** Reaching into the view hierarchy for
  it is private API, and this document already rules that out once, for
  `drawsBackground`.
- The other route is asking the page, which means JavaScript. `allowsContentJavaScript` is
  off, and host-initiated `evaluateJavaScript` is a different path that may still run — WS-09
  could not test which, because that needs a running WebView and this workstream had no GUI
  (see its report). Even if it runs, it puts a script evaluation on the path between
  clicking a message and seeing it, per message, to save one scroll surface.

The thread shape settles the rest. Siblings are collapsed and only the selected message is
expanded, so there is **one** `WKWebView` on screen at a time and therefore one WebContent
process. A 200-message thread costs 200 `NCListItem` rows and one web view. The expanding
variant inside a `ScrollView` has the same property only if it is equally careful, and it is
harder to keep careful.

What that leaves unverified, honestly: whether printing, find-in-page and selection behave
with the content rule list installed was **not** checked, for the same reason. The rule list
compiles — `MailContentRuleListTests` asserts that WebKit accepts it, including the
`^ncmail://asset/` exception — but whether it intercepts a custom-scheme load, and what it
does to `⌘P`, needs a window.

## The blocked-content bar

`NCNoteCard(.warning, …)` above the body: "This message contains remote content that was
not loaded." with **Show images** and **Always show from this sender**.

- **Show images** rewrites `data-original-src` → `src`, restores `data-original-style`,
  drops the injected `display:none!important`, and reloads from the stored HTML. No network
  request until the WebView asks for `ncmail://asset/…`.
- **Always show from this sender** additionally queues a `trustSender` operation
  ([offline-queue.md](offline-queue.md#operations)): every stored body from that address
  is marked `isSenderTrusted` in the same transaction, so the sender's other messages show
  images at once and offline, and the drainer sends
  `PUT /api/trustedsenders/{email}?type=individual` so the choice matches the web client.
- The bar is hidden when the message has no blocked content, when the sender is trusted
  (`messageBody.isSenderTrusted`), or after the user shows images for this message.

Detecting blocked content should be a scan for `data-original-src` in the stored HTML, done
once at store time and cached as a column — not on every render. **There is no such column
yet**: `messageBody` has no `hasBlockedContent`, and adding one is `NCMailStore`'s and
`NCMailSync`'s work, not WS-09's. Today the rewriter reports it as it goes, so the scan is
free — it happens inside a pass the renderer makes anyway — but it happens on every render
rather than once. The column stays the right answer, and WS-09's report asks for it.

One refinement the recorded body forced. A blocked image counts only when its
`data-original-src` is a proxy URL on the signed-in server. An original pointing anywhere
else cannot be restored, so counting it would put a bar on screen offering something **Show
images** cannot deliver.

## Printing, selection, find

`⌘P` prints the message, header and body together, from its own offscreen `WKWebView`
rather than the one on screen
([ADR-0063](../decisions/0063-printing-uses-an-offscreen-web-view.md)). The message pane
registers its header and the body it has drawn with `MessagePrintController`. The printed
document has an escaped header block (subject, from, to, cc, date — every one
attacker-controlled) and then:

- **HTML:** the already-rewritten document, with the header right after the shell's
  `<body>`.
- **Plain text:** the text escaped inside `<pre style="white-space: pre-wrap">` in the same
  shell, then the signature under an `<hr>`.

The print web view gets `MessageBodyWebView.configuration(serving:)`, the same function the
live view uses: JavaScript off, a non-persistent store, and the `ncmail` handler with the
same `Context`, so inline images print and remote images print only if unblocked. The
content rule list is installed before the load, and a rule-list failure prints nothing. It
also forces the light appearance, cancels every navigation but the first, and is held until
the print sheet's completion runs. `⌘P` is enabled only while a drawn body is registered: a
body still downloading, failed, or blocked prints nothing.

Not verified in a window: whether `didFinish` (after the load event) is late enough for every
`ncmail:` image to appear in the printout, and how WebKit paginates very wide marketing mail.

Selection spans the body but not the native header. That is the `WKWebView` default, not
verified with the content rule list installed, because verifying it needs a window.

`⌘F` is the one that has to change. This document gave it to find-in-body;
[../product/ux-spec.md](../product/ux-spec.md#keyboard) gives it to search, and search is
the answer people expect from a mail client's `⌘F`. The keyboard table wins. Find-in-body
would be `WKWebView.find(_:configuration:)` behind its own find bar, and it belongs to
whoever owns the message toolbar (WS-10) rather than being implied here.

## What is deliberately not done in v1

Itinerary cards, iMIP invitation responses, S/MIME and PGP decryption, smart replies,
thread summaries, translation. All of them are read-path features and all of them are
post-v1 — the mirror already carries the data they need in `messageBody.rawJSON`.
