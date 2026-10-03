<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0078: Server flags come from user-readable APIs or default to on; the web page is never scraped

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** WS-16, while writing `docs/reference/server-flags.md`

## Context

The web client gates thirteen behaviours on server flags (`allow-new-accounts`,
`disable-snooze`, the `llm_*` family, the OAuth URLs, `attachment-size-limit`, …), all
rendered as `initial-state-mail-*` attributes into the HTML of `GET /index.php/apps/mail/`
by `PageController::index`. Measured on the live server: capabilities carry no `mail`
section, and `GET /api/preferences/{key}` reads user preferences only (`{"value":null}` for
every flag name). Three of the flags can be read through the provisioning API, but only by
an admin — a normal user gets 403.

Three ways to learn them were open:

1. **Scrape the page.** The app password authenticates `GET /index.php/apps/mail/`, and the
   attributes are base64 JSON. Every flag, one request.
2. **Read what a normal user can read**, and treat the rest as on.
3. **Read admin-only config when the user is an admin.**

## Decision

Option 2. Each flag is read from a user-readable API where one exists — capabilities
(`dav.absence-supported` for `enable-system-out-of-office`), TaskProcessing task types (the
`llm_*` providers, `context_chat_available`), `translation/languages`, and the LLM routes'
own 204 — and a flag with none is **feature on**: the action is offered, and if the server
refuses, its message is shown verbatim. Each gap is a finding in
`docs/feedback/server-findings.md`. The per-flag sources and contingencies are in
`docs/reference/server-flags.md`. Values are stored per login (ADR-0079).

## Consequences

- No HTML parsing anywhere in the client, and no dependency on a template whose attribute
  names are an implementation detail of a Vue app.
- Five flags have no source and go through the contingency: `allow-new-accounts`,
  `disable-scheduled-send`, `disable-snooze`, `importance_classification_default`,
  `attachment-size-limit`; the two OAuth URLs are values, so their contingency is "no
  provider sign-in button". Where the server enforces the flag, the user sees its error;
  where it does not (`attachment-size-limit`, the cron-mode pair), the behaviour degrades
  the way it would for a web user on an older client.
- The same client behaves the same for an admin and a non-admin.

## Alternatives considered

**Scrape the page (1).** Complete today and cheap, but it parses HTML the network layer has
no other reason to touch, binds the client to template internals that change without notice,
and loads a page that also starts the web client's session machinery. The brief rules it out
("without the web page's initial state"), and the reason holds independently.

**Admin-only reads (3).** Accurate for admins, wrong for everyone else, and a client whose
UI depends on who is signed in is harder to reason about and to test.

## Revisit when

Mail exposes its client configuration through capabilities or an OCS route — the
server-findings entry asks for exactly that — at which point the contingency rows become
reads.
