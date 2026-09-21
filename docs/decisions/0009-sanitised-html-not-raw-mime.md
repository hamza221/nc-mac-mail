<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0009: Store the server's sanitised HTML, not raw MIME

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Architecture, from the endpoint shapes

## Context

Two ways to mirror a message body.

**Raw MIME** — `GET /api/messages/{id}/source` returns the whole RFC 822 message: one
request, everything, attachments included, byte-identical to the server's copy. Then the
client parses MIME, decodes encodings, extracts parts, and sanitises HTML itself.

**Parsed and sanitised** — `GET /api/messages/{id}/body` returns the parsed message with
attachment metadata, and `GET /api/messages/{id}/html?plain=true` returns the HTML fragment
after HTMLPurifier. Two requests, no attachment payloads, and no parsing on our side.

## Decision

Store the parsed, sanitised form. `messageBody.html` holds the `?plain=true` fragment;
`messageBody.plainBody` holds the text alternative; attachments are metadata plus on-demand
download.

`?plain=true` matters: without it the server wraps the fragment in a document containing an
iframe-resizer script and a CSP nonce (`lib/Http/HtmlResponse.php`), which is machinery for
a browser `<iframe>` and useless to us.

## Consequences

**What it buys**

- No MIME parser in this codebase. That is thousands of lines of the most bug-prone,
  most-attacked code in any mail client, and the server already has a well-exercised one.
- No HTML sanitiser either. HTMLPurifier's output is what the web client renders; we
  render the same bytes, so a rendering difference between the two clients is a bug with
  one obvious owner.
- Remote images arrive already neutralised, so the backfill cannot leak an IP through a
  tracking pixel ([../architecture/rendering.md](../architecture/rendering.md)).
- Smaller: sanitised HTML without attachments is a fraction of a raw message.

**What it costs**

- Two requests per message instead of one.
- The stored HTML is only as good as the server's sanitiser at mirror time. If the server
  improves, our copies are stale — hence `messageBody.sanitiserGeneration` and the
  re-download control.
- We cannot verify S/MIME or PGP ourselves, and cannot show raw source offline. Both are
  out of scope for v1 and both are server features we would defer to anyway.
- A future feature needing the original bytes (export as `.eml`, forwarding as attachment)
  fetches `/source` on demand. That is fine, and it is the right time to pay for it.

## Alternatives considered

**Raw MIME with client-side parsing.** A byte-complete mirror and the theoretical ideal.
Rejected on cost and risk: the parser and sanitiser are a project of their own, and they
are the two components in a mail client where a bug is a security incident.

**Both.** Storing raw alongside parsed multiplies disk for a case v1 does not have.

## Revisit when

v1.x needs `.eml` export, offline raw source, or client-side S/MIME. Even then, fetching
`/source` on demand is likely to beat mirroring it.
