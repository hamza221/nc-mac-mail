<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-20 — Rich text editor

**Wave 1, no dependencies. Size: XL.**

## Goal

A native rich text editor that produces web-client-compatible HTML
([ADR-0065](../../decisions/0065-native-rich-text-editor.md)).

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0065-native-rich-text-editor.md](../../decisions/0065-native-rich-text-editor.md) — the serialiser and importer decisions
- [../../product/ux-spec.md](../../product/ux-spec.md) — §6.5 toolbar
- `NextcloudMail/WebView/HTMLScanner.swift` — `HTMLScanner.tokens(of:)` and `HTMLEntities`,
  your importer's tokenizer

## You own

`NextcloudMail/Editor/**`

## Build

- Your first commit updates [../../product/ux-spec.md](../../product/ux-spec.md) with the
  screens and behaviour you will build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

In `NextcloudMail/Editor/`:

- `ComposerTextView: NSTextView` (TextKit 2).
- `RichTextEditor: NSViewRepresentable`, bound to `EditorDocument` (an `@Observable` wrapper
  over `NSTextStorage`), with `mode: .plain | .rich`.
- `HTMLSerializer.html(from: NSAttributedString) -> String`.
- `HTMLImporter.attributedString(fromHTML: String, baseFont: NSFont) -> NSAttributedString`
  (reusing `HTMLScanner.tokens(of:)` and `HTMLEntities.decode`).
- `PlainTextSerializer.text(from:)`.
- The fixed tag set: p, br, strong, em, u, s, sub, sup, h1–h3, ul/ol/li, blockquote,
  a[href], img[src=data:… width], span[style=color|background-color|font-family|font-size],
  div/p[dir], text-align.

**Toolbar** — parity with §6.5: heading, font family, size 9–24, B/I/U/S, colour, sub/sup,
background, image, alignment, LTR/RTL, lists, quote, link, remove format, find and replace
(`NSTextFinder`), source view (an editable HTML text view re-imported on toggle back),
undo/redo.

**Triggers** via the same API:

- `:` emoji (NextcloudUI `NCEmojiPalette`);
- `@` mention (asks a `MentionProvider` protocol, implemented later by WS-26);
- `!` text block (`TextBlockProvider` protocol, implemented by WS-27);
- `/` Smart Picker (`SmartPickerProvider` protocol, implemented by WS-27).

Rules that are easy to get wrong:

- **Paste**: the readable pasteboard types are restricted to RTF, RTFD, plain text, images
  and HTML. HTML goes through `HTMLImporter` only, so pasting never makes a network request.
  Pasted or dropped files are attachments, emitted through an `onFileDrop` callback.
- Turning formatting off asks "Turn off and remove formatting" / "Keep formatting".
- The code must not depend on mail types: it is designed to be upstreamed
  ([ADR-0065](../../decisions/0065-native-rich-text-editor.md)).

Ships with a debug-only `EditorPlayground` view.

## Acceptance

- HTML → editor → HTML is a fixed point for every construct in the tag set (unit tests).
- Pasting from Safari makes no network request (manual check with the network monitor).
- VoiceOver reads the toolbar.

## Out of scope

The composer window, attachments and recipients around the editor (WS-27). The
`MentionProvider` implementation (WS-26). The `TextBlockProvider` and `SmartPickerProvider`
implementations (WS-27). Drafts and sending (WS-23). Settings that choose plain or rich mode
(WS-39).

## Report

Additionally: the library-feedback entry proposing this editor as `NCRichContenteditable`
for NextcloudUI, and where TextKit 2 fell short of §6.5.
