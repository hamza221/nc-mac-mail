# ADR-0002: Authenticate with an app password obtained through Login Flow v2

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** Carried over from `plan/macos-client.md`; the CSRF mechanism verified in `nextcloud/server`

## Context

Nextcloud Mail's app routes live under `/index.php/apps/mail/api/` and are not OCS routes.
Most of them require a `requesttoken` CSRF header, which a browser session has and a native
client does not.

`passesCSRFCheck()` in `lib/private/AppFramework/Http/Request.php` returns `true` as soon
as the `OCS-APIRequest` header is present, and `cookieCheckRequired()` returns `false` for
a request carrying no session cookie. So HTTP Basic with an app password, plus that one
header, is accepted.

## Decision

Login Flow v2 in the system browser, an app password stored in the Keychain, HTTP Basic
plus `OCS-APIRequest: true` on every request. No session cookies, ever — the client's
`URLSession` refuses to accept or send them.

The `User-Agent` on the flow's first request is `Nextcloud Mail (macOS)`, because that
string becomes the app password's name in the user's security settings.

## Consequences

- The user's Nextcloud password never touches this app, including on an SSO instance where
  there is no password to type.
- Access is revocable per device, server-side, by name.
- Credentials survive relaunch through the Keychain, so sign-in happens once.
- The whole client depends on the CSRF behaviour above. **WS-01 verifies it with
  `Scripts/smoke-auth.sh` against a real instance before writing Swift.** A 412 there means
  the fallback is a session cookie plus a scraped `requesttoken`, which reshapes several
  workstreams — so it is checked first, not discovered later.
- A stray cookie silently breaks authentication, which is why cookie storage is disabled
  rather than merely unused.

## Alternatives considered

**Username and password over Basic.** Works, and asks the user to hand a native app their
Nextcloud password. No.

**OAuth 2 against the server.** Nextcloud's OAuth is for third-party integrations and needs
admin-registered clients. Wrong shape for a first-party desktop client.

**Session cookie plus scraped `requesttoken`.** The fallback if the above fails. Fragile:
it depends on an HTML page's contents and on session lifetime.

## Revisit when

The smoke test fails, or Nextcloud publishes a device-authorisation flow that supersedes
Login Flow v2.
