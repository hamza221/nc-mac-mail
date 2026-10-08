<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0106: Link disagreement is recorded per anchor, keyed by a normalised target

**Status:** Accepted
**Date:** 2026-10-08
**Decided by:** the security audit of 2026-10, which bypassed the link confirmation three
ways, and a check of the fix against the URLs WebKit actually reports on click

## Context

The link confirmation ([rendering.md](../architecture/rendering.md), "The WebView") needs
the anchor's visible text, and a cancelled navigation carries only a URL. The rewriter
collected `linkTexts: [href: text]` and the navigation delegate looked up
`linkTexts[url.absoluteString]`. The audit got past it three ways:

- **One text per `href`.** The first text that named a host was kept, agreeing or not. An
  honest `evil.test` footer link, or a `display:none` one, before a lying `paypal.com` link
  on the same `href` hid the lie.
- **Two spellings of one URL.** The key was the `href` as written; the lookup was WebKit's
  WHATWG-canonical form. `https://login.evil.test` is reported as `https://login.evil.test/`,
  `https://Login.Evil.test/u` lower-cased, `?a='b` as `?a=%27b`. The lookup missed, and a
  miss opened the link without a question.
- **The text's claim.** `paypal.com/signin`, `paypal.com:443` and `paypal.com.` were read
  as claiming no host.

The last is a parsing fix inside `LinkDisagreement.claimedHost`. The first two are about
what is recorded and how a click finds it.

## Decision

- The rewriter works out `LinkDisagreement.verdict` for **each anchor** when it closes,
  from the anchor's text bounded to 512 UTF-8 bytes on append. `LinkVerdicts` keeps the
  first disagreeing verdict per target and per host; agreement only fills an empty slot.
  Every `http(s)` anchor is recorded, empty and "Shop now" text included.
- The target is a `LinkTarget`, built by one normaliser that both the rewriter (from the
  `href`) and the click (from WebKit's URL) go through. It reproduces WebKit's parse where
  that decides the host — tabs and newlines removed, any run of `/` or `\` after the scheme,
  the authority after the last `@` and before `:`, percent-decoding, ASCII lower-casing,
  dot-segment resolution including `%2e` — and merges where merging is harmless: no port,
  no user, no fragment, path and query compared decoded and lower-cased.
- Where it cannot be sure which host WebKit will report (any non-ASCII after
  percent-decoding, which IDNA maps; an IPv6 literal; a number that is not a canonical
  dotted quad), the anchor has no target. Its claimed host is checked against **every**
  click instead, so it cannot borrow an honest twin's verdict.
- A click asks if an unplaced claim disagrees with the clicked host, else answers from the
  target table, else from the host table. If neither has an entry, it asks, showing the URL:
  every anchor was recorded, so no entry means an anchor was read differently from how
  WebKit read it and its text is unknown.
- `RenderedMessage.verdict(for:)` is the one call both of the web view's link callbacks
  make.

## Consequences

- An honest anchor cannot vouch for a lying one on the same target, in either order.
- The audit's spellings and the routes by which WebKit rewrites one `href` onto another
  (`3221225985` to `192.0.2.1`, `login。evil。test` to `login.evil.test`,
  `/a/b%2F../../x` to `/a/x`) all ask. Each was checked by clicking the anchor in a
  `WKWebView` on macOS 26 and normalising the URL WebKit reported.
- The cost is questions on some honest links: a message whose IDN or numeric-host link has
  text naming a host makes every other link in it ask, and a link to an IPv6 literal always
  asks. Real mail is mostly ordinary DNS names, and the recorded body still asks nothing.
- The normaliser models WebKit's URL parser. If WebKit's parse changes in a way that
  moves a host, the miss now asks rather than opens, but a collision with an honest twin
  would not be caught.
- Text beyond 512 bytes is not read. An attacker could already put a word after the host
  ("paypal.com login"); the bound only stops a long text costing work.

## Alternatives considered

**Key by host only.** Removes the dependence on path spelling, and was the audit's
suggestion. But a marketing mail whose footer reads `www.brand.com` through the click
tracker would make every "Shop now" link through the same tracker ask, quoting the footer.

**Open when nothing is recorded, as before.** Keeps the "Shop now must not ask" rule by
default. With every anchor recorded, "Shop now" no longer depends on it, and a miss only
happens when the two parsers disagree — the case to be suspicious of.

**Carry the anchor's identity into the click** (a per-anchor marker in the `href`). The
navigation callback gets only the URL WebKit made, so the marker would have to survive
WebKit's rewriting, be removed again before `openURL`, and be unforgeable by a sender who
can write the same marker into another `href`. Each is a new way to be wrong.

## Revisit when

WebKit hands the navigation delegate anything that identifies the clicked element, or the
link-confirmation rule moves to the server.
