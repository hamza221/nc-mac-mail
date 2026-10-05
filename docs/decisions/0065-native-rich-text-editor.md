<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0065: The composer is a TextKit 2 `NSTextView` this app owns, serialising to HTML itself

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** product owner, v2 planning

## Context

v2 brings a composer (ADR-0064). A mail composer must produce HTML, round-trip quoted
content, and feel native. The obvious shortcuts are all traps: `NSAttributedString`'s HTML
export emits CSS-heavy, Word-like markup; `NSAttributedString(html:)` runs WebKit and can
fetch remote resources; a contenteditable web view is a second scriptable web view to
secure. The app already has its own HTML machinery (`HTMLScanner`, `HTMLEntities` in
`NextcloudMail/WebView/HTMLScanner.swift`), and NextcloudUI has deferred its own rich
editor to v1.1.

## Decision

The composer is a TextKit 2 `NSTextView` this app owns, serialising to HTML itself.

- What is serialised: the editor holds only what the user writes. The original being
  replied to or forwarded is kept as the server's sanitised HTML and attached at send time
  inside `<blockquote type="cite">`. It is shown read-only under the editor through the
  existing message web view. "Edit quoted text" imports it into the editor through
  `HTMLImporter`, accepting the loss.
- Serialiser: our own `HTMLSerializer` over a fixed tag set. Not `NSAttributedString`'s
  HTML export, which emits CSS-heavy, Word-like markup.
- Importer: our own `HTMLImporter`, built on `HTMLScanner.tokens(of:)` and `HTMLEntities`
  in `NextcloudMail/WebView/HTMLScanner.swift`. It never uses `NSAttributedString(html:)`,
  which runs WebKit and can fetch remote resources.
- Upstreaming: the editor is designed to be upstreamed as `NCRichContenteditable` to
  NextcloudUI (deferred there to v1.1 per its ROADMAP), so the code must not depend on
  mail types.

## Consequences

- The editor is native text editing — macOS spelling, dictation, substitutions and
  accessibility come for free, and no new scriptable surface is added.
- Outgoing HTML is ours: a fixed tag set the serialiser emits and the importer reads, so
  round trips are lossless within that set.
- The cost is owning a serialiser and an importer, and "Edit quoted text" is lossy by
  design: arbitrary mail HTML collapses to the fixed tag set when imported.
- Keeping the quote out of the editor means reply bodies stay the server's sanitised HTML,
  untouched, until send time.

## Alternatives considered

**A WKWebView contenteditable editor.** A second scriptable web view to secure, and less
Mac-like.

**Waiting for NextcloudUI's `NCRichContenteditable`.** Deferred there to v1.1; v2 cannot
wait on it. Building ours to be upstreamable gets both.

**`NSAttributedString` HTML export/import.** The export emits CSS-heavy, Word-like markup;
the import runs WebKit and can fetch remote resources.

## Revisit when

NextcloudUI ships `NCRichContenteditable`.
