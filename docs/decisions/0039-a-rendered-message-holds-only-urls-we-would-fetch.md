<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0039: A rendered message holds only URLs we would fetch

**Status:** Accepted
**Date:** 2026-09-23
**Decided by:** WS-09, while rewriting the recorded body

## Context

[ADR-0010](0010-webview-scheme-handler.md) says every image URL is rewritten to
`ncmail://asset/{base64url(original)}` and that the scheme handler is an allowlist. It does
not say what happens to a URL the allowlist would refuse, and the recorded body has four of
them: a `@import` of a font stylesheet on `static-forms.klaviyo.com`, the server's own
`/apps/mail/img/blocked-image.png` placeholder on nine images, a 1×1 tracking pixel the
server stripped the URL from, and thirteen links to a click tracker.

Three shapes were possible for each: rewrite it, neutralise it into something harmless that
is still a URL, or remove it.

## Decision

**A rendered document contains no URL that would cause a load, except `ncmail://asset/…`
and `data:image/…`.** Anything the allowlist refuses is removed rather than neutralised.

Concretely, in `MessageHTMLRewriter`:

- `src`, `srcset`, `background`, `poster` and `url(…)` are classified with
  `MailAssetPolicy`, which is the *same* function the scheme handler calls. A URL it
  accepts becomes an asset URL; a URL it refuses takes its attribute with it, and a refused
  `url(…)` becomes `none`.
- `@import` is deleted, rule and all.
- `data:` survives only for `data:image/…` and never for `data:image/svg+xml`. An SVG is a
  document with its own external references, not a picture.
- The server's blocked placeholder is removed rather than loaded. It is on our own server
  and would authenticate, and it is still nine requests for a picture of nothing behind
  images the server has already set to `display:none`.
- `data-original-src` is kept only when it is a proxy URL on the signed-in server. An
  original pointing anywhere else cannot be restored by **Show images**, so counting it as
  blocked content would put a bar on screen promising something the button cannot do.
- `href` keeps `http`, `https`, `mailto` and `tel`. `javascript:`, `data:` and everything
  else lose the attribute — and the check runs on the entity-decoded value, so
  `&#106;avascript:` is the same string as `javascript:` by the time it is tested.

The MIME type is checked a second time at serve time: the handler refuses anything that is
not `image/*`, and refuses `image/svg+xml` there too.

## Consequences

- The security property is one assertion over the output rather than a reading of the code:
  *extract every loadable URL from the rendered document; the list is empty, or it is all
  `ncmail:`*. `MessageHTMLRewriterTests` asserts exactly that for the recorded body, for the
  recorded body with images unblocked, and for a hostile document written to get past the
  rewrite.
- The allowlist exists once. A rewriting bug cannot widen what the handler serves, and a
  handler bug cannot be reached by a URL the rewriter would not have written.
- Some mail loses a font or a background image that the server would happily have proxied
  through `/proxy`, because only `<img>` gets the server's `TransformImageSrc` treatment —
  CSS does not. Those messages render in the system font. That is the right trade: the
  alternative is fetching from a third party, or proxying a URL the server never signed.
- A message quoting a `javascript:` URL as *text* still shows the text. Only the attribute
  goes.

## Alternatives considered

**Neutralise instead of remove** — rewrite refused URLs to `about:blank` or a bundled
placeholder. It keeps the document closer to what the sender wrote, and it leaves URLs in
the document that a later change could accidentally start honouring. The content rule list
would still block them, which is precisely the argument for not depending on it.

**Trust the content rule list alone.** It is layer three and it is not a reason to skip
layer two. A rule list is a WebKit feature with WebKit's bugs; the document is ours.

**Allow SVG.** Some senders use SVG logos. With JavaScript off and the rule list installed
an SVG is probably harmless, and "probably harmless document format with its own parser" is
not a thing to put in front of a mail body for a logo.

## Revisit when

A real message is shown to render badly because a CSS background was dropped, or Nextcloud's
sanitiser starts rewriting CSS URLs the way it rewrites `<img>`.
