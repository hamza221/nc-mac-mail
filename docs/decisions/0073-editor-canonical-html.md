<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0073: The editor serialises one canonical HTML form, and import makes any input canonical

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-20, building the serialiser and importer ADR-0065 ordered

## Context

ADR-0065 fixes the tag set (p, br, strong, em, u, s, sub, sup, h1–h3, ul/ol/li, blockquote,
a[href], img[src=data:… width], span[style], div/p[dir], text-align) but not the shape of
the markup inside it. HTML offers many spellings of the same text — `<em><strong>` versus
`<strong><em>`, `#F00` versus `#ff0000`, pretty-printed versus packed, `<div>` versus
`<p>`, `&nbsp;` versus U+00A0 — and the acceptance test is that HTML → editor → HTML is a
**fixed point**. A fixed point over "whatever the attributed string happens to produce" is
unverifiable; it has to be a fixed point over a defined grammar.

## Decision

`HTMLSerializer` emits exactly one spelling — the canonical form — and `HTMLImporter`
accepts anything the tag set can express, so one import-serialise pass makes any input
canonical and every later pass is the identity. The canonical form:

- **Blocks** are `p`, `h1`–`h3`, `li` (inside one `ul`/`ol` per contiguous run) and any of
  those wrapped in one `blockquote` per contiguous quoted run. Blocks are packed with no
  whitespace between tags. `div` imports as `p`; nested lists flatten to the innermost list
  kind; nested blockquotes flatten to one level.
- **Block attributes**: `dir` first (`rtl`/`ltr`, only when the paragraph's writing
  direction was set explicitly), then `style="text-align:left|center|right|justify"` (only
  when alignment was set explicitly — natural emits nothing).
- **Inline nesting order**, outermost first: `a`, `span`, `strong`, `em`, `u`, `s`, then
  `sub` or `sup`. Adjacent runs diff against each other, so `<strong>a <em>b</em></strong>`
  stays one `strong`. `b`/`i` import as `strong`/`em`.
- **`span` style properties** in the order `color`, `background-color`, `font-family`,
  `font-size`, joined by `;` with no spaces and no trailing semicolon. Colours are
  lowercase `#rrggbb` in sRGB; sizes are integer `px`, mapped 1:1 to points. Only colours
  the user set serialise: system (catalog) colours are the view's appearance, not content.
- **Text** escapes `&`, `<`, `>` and nothing else; U+00A0 stays a raw character. Inside a
  block, text is verbatim — consecutive spaces are not collapsed and not turned into
  `&nbsp;` (mail renderers collapse them visually; the bytes round-trip). Between blocks,
  whitespace-only text is dropped, and newlines inside inline text import as single spaces.
- **`br`** is a line break inside a paragraph (U+2028 in the attributed string); `\n`
  separates paragraphs. n blocks ↔ n−1 separators, so there is no trailing-newline
  ambiguity. An empty document serialises to `<p></p>`.
- **Headings** carry their size in the element: a run whose font is exactly the heading's
  derived font (bold, scaled from the base font) emits no inline tags, so `<h1>x</h1>`
  round-trips without a `font-size` span.
- **`img`** keeps the original `src` string byte-for-byte in a custom attribute — the image
  is decoded for display but never re-encoded, because a PNG round-tripped through
  `NSImage` is not the same bytes. `width` is emitted when known. Only `data:` sources
  import; any other `src` is dropped, which is also the security property: the model cannot
  hold a fetchable reference. `a[href]` imports only `http`, `https` and `mailto`.
- Anything outside the tag set imports as its text content — the "accepting the loss" of
  ADR-0065's Edit-quoted-text, applied uniformly.

Block identity lives in one custom attribute (`.editorBlock`) rather than being inferred
from fonts and indents, so "is this a heading" has one answer for the serialiser, the
toolbar state and the remove-format command.

## Consequences

- The fixed-point acceptance test is mechanical: every construct has a canonical fixture,
  `serialize(import(x)) == x`; for non-canonical input the test is idempotence after one
  pass. Both are unit tests with no view involved.
- Outgoing mail HTML is small and boring — no CSS classes, no Word-like markup — which is
  what the web client's sanitiser keeps anyway.
- The cost is lossiness at the edges the web editor also fudges: nested lists flatten,
  `&nbsp;`-encoded spacing becomes a plain character, and pasted markup outside the set
  collapses to text.
- The canonical order is load-bearing: changing it later invalidates recorded fixtures and
  any draft HTML round-tripping through an old build, so it changes by superseding this
  record.

## Alternatives considered

**Fixed point over the importer's output only** (serialise whatever the attributed string
contains). Unverifiable: two serialisations of visually identical documents could differ,
and drafts would churn on every open.

**Normalising whitespace like a browser** (collapse runs, emit `&nbsp;` pairs). Breaks the
byte-level fixed point for the one thing users notice surviving — their own spacing — to
gain fidelity with renderers we do not control.

**Inferring blocks from presentation** (bold 2× font ⇒ h1). One wrong font comparison away
from misclassifying user text; an explicit attribute cannot drift.

## Revisit when

The editor is upstreamed as `NCRichContenteditable` and another consumer needs a different
canonical form, or the web client's sanitiser starts rejecting any spelling chosen here.
