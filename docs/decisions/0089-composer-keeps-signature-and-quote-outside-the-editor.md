<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0089: The composer keeps the signature and the quote outside the editor, and hides its window during a send

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-27

## Context

The web client inserts the signature into the editor body and finds it again by markup
when From changes; its quote is editor content too. ADR-0065 already keeps the quote out of
our editor (the server's sanitised HTML, shown read-only, joined at send time). The
signature has the same problem: our editor serialises a fixed tag set, so an HTML
signature round-tripped through it is no longer recognisable, and "replace the signature
when the alias changes" (§6.4) becomes a text search over the user's own words.

Sending has a second shape question. §6.9 says the composer "hides" on Send and Undo
"reopens" it. A SwiftUI window that is closed loses its state, and the drafts engine's undo
window (ADR-0083) can still hand the draft back.

## Decision

- The signature is held by the composer model, shown read-only under the editor, and
  joined at send time with the quote, in the order the account's "Place signature above
  quoted text" and the `reply-mode` preference give. Changing From replaces it exactly.
  Drafts reopened from the server already contain theirs and get none added.
- On Send the composer writes the row, calls `OutboxSender.send`, and orders its window
  out. It follows the row: gone means sent (the window closes), a cleared `sendState` means
  undone (the window comes back as "Edit message"), `failed` brings it back with the reason.
  The undo banner in the main window reaches the hidden window through `ComposerWindows`.

## Consequences

- From changes are exact and cheap; the signature cannot be edited per message in the
  composer (the web client allows that). Editing it is a Settings change (WS-39).
- Undo is instant and loses nothing: the editor, its undo stack and the fields are the
  same objects. A relaunch inside the window restores the hidden window from the row.

## Alternatives considered

**Signature in the editor, found by a marker.** The fixed tag set would strip or rewrite a
marker attribute, and a user edit can break it; replacement would then duplicate signatures.

**Close on Send, rebuild from the row on Undo.** Loses the editor's undo stack and the
read-only quote, and needs a `ComposeRequest` case for a local row, which the shared enum
does not have.

## Revisit when

Users ask to edit the signature per message, or the editor gains non-editable regions.
