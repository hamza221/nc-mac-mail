<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0094: OAuth account setup observes completion by polling the connection test

**Status:** Accepted
**Date:** 2026-10-04
**Decided by:** WS-40

## Context

The web client opens the provider's consent page in a 600×700 pop-up. The provider
redirects to the *server's* handler (`mail.googleIntegration.oauthRedirect` /
`mail.microsoftIntegration.oauthRedirect`, an `https` route on the Nextcloud host), which
stores the token and renders `OauthDone.vue`; that page `postMessage`s `DONE` to its
opener. A closed pop-up is `CONSENT_ABORTED`, and the temporary account is deleted.

The brief asks for `ASWebAuthenticationSession`. A session completes only when the page
navigates to its callback — a custom scheme, or (macOS 14.4+) an `https` host the app has an
associated-domains entitlement for. The server's redirect target is neither: it is the
user's own Nextcloud host, unknowable at build time, and it never redirects onwards. So the
session cannot observe completion.

## Decision

- The consent page opens in an `ASWebAuthenticationSession` (callback scheme
  `nc-mail-oauth`, never redirected to). It is the window and nothing more.
- Completion is the connection test turning true: `SettingsCommands.testConnection` every
  2 s, for up to 10 minutes, reading the `accountTest` row. A granted poll cancels the
  session and the flow continues to "Loading account".
- The session completing (the user closing it), the sheet's Cancel, or the 10-minute limit
  is "Authorization pop-up closed"; the temporary account is deleted with
  `SettingsCommands.deleteAccount`, as the web client does.
- If the session cannot start, the default browser opens the URL and the same poll runs;
  Cancel and the limit are then the only ways out.

## Consequences

- Works against any server, without an entitlement or a server change.
- A denied consent is not detected as such: the test stays false until the user closes the
  window or the limit passes. The web client has the same gap (§1.4 ⚠ "Deny consent").
- Up to 300 test requests in the worst case, each an IMAP login attempt server-side for an
  account with no token yet — cheap, and bounded.

## Alternatives considered

**`https` callback with associated domains.** Needs the user's host in the entitlement at
build time; impossible for a client of arbitrary servers.

**A server change redirecting the done page to `nc-mail-oauth://done`.** Cleanest, but out
of this project's reach; noted in `docs/feedback/upstream-issues.md` terms as a possible
upstream ask.

**`WKWebView` sheet observing navigation to the done route.** Observes completion exactly,
but embeds a provider login in an app-owned web view, which Google rejects
(`disallowed_useragent`) and users rightly distrust.

## Revisit when

The server can redirect its OAuth done page to a client-supplied callback URL.
