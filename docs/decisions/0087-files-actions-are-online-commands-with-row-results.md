<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0087: Files share links and image embeds are online-only commands whose results are rows

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-33

## Context

WS-33 adds four Files actions. Two of them change nothing the user can wait for: attaching
a Files path to a draft (a local `draftAttachment` row the server resolves at send time) and
saving an attachment or message to Files (the queued `saveToFiles` kind). The other two need
an answer while the person is still typing: "Add share link" must paste a URL that only
the server can mint, and "Insert image from Files" must embed bytes that only the server
holds. Neither can be queued — a link that exists hours from now cannot be pasted now —
and neither may be returned to a view by a network call (ADR-0003, ADR-0067).

## Decision

- `FilesListingSync` (one per login, NCMailSync) owns every Files request: the PROPFIND
  listings (ADR-0067 rows in `filesListing`), `createShareLink(path:)` and
  `stageImage(_:)`.
- The two immediate actions follow ADR-0068's shape: the caller awaits only a
  `CommandOutcome`. On success the engine writes a `serverResult` row —
  `filesShareLink` (`{"url"}`) or `filesImage` (`{"localPath","mime"}`), keyed by the Files
  path — and the caller reads that row and hands it to the editor (`applyLink` /
  `insertImage(at:)`). The image bytes go to a staging file, never into the database.
- Insert image refuses anything other than png/jpeg/gif/bmp/webp or over 10 MB *before*
  sending, from the listing, and again on the bytes received.
- A Files attachment is a `draftAttachment` of kind `cloud` with payload
  `{"type":"cloud","fileName":path}` — the server's own attachment type — not a download
  and re-upload.
- `filesListing.entriesJSON` carries ADR-0067's envelope (`ready` / `failed`), so a folder
  that never loaded can stop its spinner; a failure never overwrites a ready listing.
  Expiry is 60 s.

## Consequences

- Views stay database readers; the only awaited value is an outcome.
- Share links and image embeds cannot happen offline; the UI says so instead of queueing.
- A share link is created on every use, as in the web client; nothing deduplicates them.

## Alternatives considered

**A queue kind for share links.** The replay would mint a link after the message was
sent without it.

**Return the URL / bytes from the engine call.** One fewer read, but it is exactly the
"view awaits network data" ADR-0067 forbids, and the second exception would follow.

**Download and upload Files attachments as local attachments.** Doubles the traffic and
loses the server-side copy the web client relies on.

## Revisit when

The editor gains a way to insert a pending placeholder that the engine fills, or the
server offers share links that can be minted offline (pre-reserved tokens).
