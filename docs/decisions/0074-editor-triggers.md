<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0074: Editor triggers are one session API; `:` opens the system emoji palette

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-20, mapping §6.5's CKEditor triggers to AppKit

## Context

The web editor has four in-text triggers: `:` emoji, `@` mention, `!` text block, `/` Smart
Picker. Each filters a suggestion list by the characters typed after the trigger. The brief
fixes two ends: the trigger characters must behave like the web client's, and `:` uses
NextcloudUI's `NCEmojiPalette` — which is the **system** character palette, a panel that
inserts into the focused view and takes no query string. The editor must also stay free of
mail types, so it cannot know what a mention or a text block *is*.

## Decision

One session mechanism in `ComposerTextView`: a trigger character typed at a word boundary
(paragraph start or after whitespace) opens a session; everything typed after it is the
query; Escape, Space, or moving the caret out of the session cancels; deleting past the
trigger cancels.

- `@`, `!`, `/` surface the session as `(kind, query, caret rect)` on `EditorDocument`, and
  the SwiftUI layer shows a popover anchored at the caret listing whatever the injected
  `MentionProvider` / `TextBlockProvider` / `SmartPickerProvider` returns. The editor
  defines the provider protocols and the three result value types (name+email, title+HTML,
  title+URL); WS-26/WS-27 implement them. No provider ⇒ the trigger is inert and the
  character is just text.
- `:` cannot feed a query into the system palette, so it maps differently: the trigger
  opens `NCEmojiPalette` immediately. The palette inserts at the caret; when the next
  insertion starts with an extended-pictographic scalar the editor deletes the trigger
  colon, so "😀" lands where ":smile" would have. Any other keystroke — including the
  Space the web client also cancels on — ends the session and keeps the colon, so typing
  "Note: see below" never loses a character.

## Consequences

- One detection path, four behaviours; WS-26/27 plug in data without touching the editor.
- The emoji flow is native and complete (search, skin tones, recents) at zero maintenance,
  which is the same trade `NCReactionPicker` makes.
- The cost: no inline `:sm`-style filtering — the palette has its own search field — and
  the colon-removal heuristic is scalar-based, so inserting an emoji by any other means
  within an open session also consumes the colon. Both are edge cases a composer user
  recovers from with one keystroke.
- Suggestion popovers are mouse-first in v2: Escape cancels from the keyboard, but arrow-key
  navigation of the candidate list is WS-27 polish, noted in its brief's integration pass.

## Alternatives considered

**An emoji provider like the other three.** Rebuilds the palette grid NextcloudUI already
declined to build (see `NCEmojiPalette`'s doc comment); goes stale with each Unicode
release; loses recents and skin tones.

**Opening the palette only on `:` + a letter.** Closer to the web client's filter feel, but
the palette ignores the letters anyway, so the extra state buys nothing and loses the
palette-on-demand simplicity.

**No `:` trigger (⌃⌘Space exists).** Fails §6.5 parity, and the discoverability of `:` is
the point for people who live in the web client.

## Revisit when

`NCEmojiPalette` grows a query parameter (it cannot today — AppKit's palette has no API),
or NextcloudUI ships its own emoji picker component.
