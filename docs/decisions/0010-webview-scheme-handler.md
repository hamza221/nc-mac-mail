# ADR-0010: Serve body images through a custom URL scheme

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture, forced by WKWebView's subresource behaviour

## Context

Both kinds of image in a Nextcloud mail body sit behind an authenticated endpoint:

- inline attachments (`cid:`) resolve to `…/api/messages/{id}/attachment/{aid}`;
- unblocked remote images resolve to `…/apps/mail/proxy?src=…&id=…&hmac=…`.

`WKWebView` will not attach our `Authorization` header to subresource loads. The web client
does not have this problem because it has a session cookie — and giving this client a
session cookie is precisely what [ADR-0002](0002-app-password-login-flow-v2.md) forbids, on
pain of breaking authentication entirely.

## Decision

Before loading, every image URL in the stored HTML is rewritten to

```
ncmail://asset/{base64url(original absolute URL)}
```

and served by a `WKURLSchemeHandler` that decodes the URL, verifies it points at the
signed-in server, fetches it through the authenticated `MailClient`, and returns the bytes.

- **Inline attachments** are stored in `attachment.data` on first fetch, so a message read
  once shows its pictures offline.
- **Proxied remote images are never stored.** Storing them would give a tracking pixel a
  permanent home on the user's disk in exchange for nothing.
- Anything that is not one of those two shapes fails the load. The handler is an allowlist.

## Consequences

- Inline images work, offline included, with no cookie and no credential inside the
  WebView.
- The app decides, per request, whether a remote fetch is allowed — so "show images" is
  enforced in Swift rather than trusted to the page.
- The content rule list can then block *every* scheme except `ncmail:`, which means even a
  sanitiser failure cannot produce an outbound request.
- The handler runs on the main thread and must hand off immediately; a slow database read
  there stutters the WebView.
- HTML rewriting happens in Swift with no JavaScript available — a string transformation
  over known attributes (`src`, `data-original-src`, `srcset`, `background`, and `url()` in
  inline styles), tested against recorded fixtures rather than invented ones.

## Alternatives considered

**`data:` URIs inlined into the HTML.** No handler, no rewriting of load behaviour — and a
4 MB image becomes 5.5 MB of base64 in a document the WebView re-parses on every layout.
Rejected on memory and latency.

**A local HTTP server on 127.0.0.1.** Works, and adds a listening socket, a port, and an
authentication problem of its own. Worse in every dimension.

**A session cookie in the WebView's data store.** Breaks the app's authentication model and
would be the one place a cookie exists. No.

## Revisit when

WebKit offers per-request authentication for subresources, which would remove the need for
the scheme entirely.
