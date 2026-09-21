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
  navigation. A link click is cancelled and handed to `NSWorkspace` — after a confirmation
  when the visible link text disagrees with the target host, which is the cheapest
  anti-phishing control there is and one the web client has a whole detector for.
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
- **anything else** → fail the load. The handler is an allowlist, not a proxy.

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
needs a content height, which without JavaScript means `WKWebView.sizeToFit`-style layout
observation. WS-09 prototypes both and picks on evidence, checking each against
find-in-page, printing, text selection across the seam, and a 200-message thread. Whichever
wins, record the measurement and the reason here.

## The blocked-content bar

`NCNoteCard(.warning, …)` above the body: "This message contains remote content that was
not loaded." with **Show images** and **Always show from this sender**.

- **Show images** rewrites `data-original-src` → `src`, restores `data-original-style`,
  drops the injected `display:none!important`, and reloads from the stored HTML. No network
  request until the WebView asks for `ncmail://asset/…`.
- **Always show from this sender** additionally calls
  `PUT /api/trustedsenders/{email}?type=individual`, so the choice matches the web client
  and is stored server-side, where it belongs.
- The bar is hidden when the message has no blocked content, when the sender is trusted
  (`messageBody.isSenderTrusted`), or after the user shows images for this message.

Detecting blocked content is a scan for `data-original-src` in the stored HTML, done once
at store time and cached as a column — not on every render.

## Printing, selection, find

`⌘P` prints the message. `⌘F` inside the message pane finds within the body. Selection
spans the body but not the native header. All three are `WKWebView` defaults; the thing to
verify is that they still work once the content rule list is installed, which is exactly
the kind of surprise this workstream exists to find.

## What is deliberately not done in v1

Itinerary cards, iMIP invitation responses, S/MIME and PGP decryption, smart replies,
thread summaries, translation. All of them are read-path features and all of them are
post-v1 — the mirror already carries the data they need in `messageBody.rawJSON`.
