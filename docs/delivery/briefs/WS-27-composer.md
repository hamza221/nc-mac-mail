<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# WS-27 — Composer and outbox view

**Wave 3, after WS-20, WS-22, WS-23, WS-25, WS-26. Size: XL.**

## Goal

§6 parity in a native compose window.

## Before you start

- [../../../AGENTS.md](../../../AGENTS.md)
- [../../architecture/overview.md](../../architecture/overview.md)
- [../../decisions/0003-local-first-full-mirror.md](../../decisions/0003-local-first-full-mirror.md)
- [../../decisions/0064-v2-parity-scope.md](../../decisions/0064-v2-parity-scope.md)
- Your own rows in [../../product/parity.md](../../product/parity.md)
- [../../decisions/0065-native-rich-text-editor.md](../../decisions/0065-native-rich-text-editor.md) — the editor you embed
- [../../decisions/0066-drafts-and-outbox.md](../../decisions/0066-drafts-and-outbox.md) — the drafts and sending engine you drive

## You own

`NextcloudMail/Views/Composer/**`, `NextcloudMail/Views/Outbox/**`

## Build

- `ComposerScene`: `WindowGroup(id: "composer", for: ComposeRequest.self)`. One window per
  draft; web "minimise" maps to window minimise; closing saves and closes the draft.
- Fields: From (accounts + aliases), To/Cc/Bcc chip fields with
  `RecipientSuggestionProvider` (built on NextcloudUI `NCUserPicker`/`NCChip` where they
  fit; gaps go to library feedback), Subject, `RichTextEditor`, attachments strip (upload,
  Files via WS-33, share link, drag and drop, paste).
- Reply and forward rules from §6.1, including localized prefix de-duplication (AW:, SV:,
  WG:, TR:, 回复:).
- Signature and quote placement from §6.6. `mailto:` parsing (`ComposeRequest.new(mailto:)`).
- Warnings: no subject, forgotten attachment, empty To, noreply.
- "…" menu: Smart Picker, text blocks, send later presets (09:00 / 14:00 / Monday 09:00 /
  custom), read receipt, mark as AI generated, S/MIME sign/encrypt.
- Undo-send banner in the main window. Quit with unsaved composers asks to save.
- Outbox view (`Views/Outbox/`) for §4.9.

Rules that are easy to get wrong:

- **Your one cross-boundary edit** is the standing exception: the single line registering
  `ComposerScene()` in `NextcloudMail/App/NextcloudMailApp.swift`. Nothing else outside
  your folders.
- **Drafts and sending are WS-23's engine** (ADR-0066): the composer saves drafts and
  hands off sends; it never talks HTTP itself.
- Your first commit updates `docs/product/ux-spec.md` with the screens/behaviour you will
  build, so reviewers check against a written spec.
- Every parity row you own moves to `Done` in `docs/product/parity.md` in your PR, with the
  evidence (test name or manual check) in the note column.

## Acceptance

- Every §6 row except Mailvelope, demonstrated live.
- Offline compose and send.

## Out of scope

The drafts and outbox sending engine (WS-23). The rich text editor itself (WS-20). The
Files picker your attachments strip opens (WS-33). The recipient suggestion provider and
contact card (WS-26). Queue kinds and settings commands (WS-22). The app shell and window
plumbing beyond the one registered scene line (WS-25).

## Report

Additionally: where NextcloudUI's `NCUserPicker`/`NCChip` fell short and what you filed as
library feedback, and how the one-window-per-draft model held up under quit-with-unsaved.
