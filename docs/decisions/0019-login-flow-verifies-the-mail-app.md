<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0019: `LoginFlow` proves the Mail app exists before reporting success

**Status:** Accepted
**Date:** 2026-09-22
**Decided by:** WS-01, against a live instance (`Scripts/smoke-auth.sh http://nextcloud.local admin admin`)

## Context

[S-01](../product/user-stories.md#s-01-sign-in-ws-01) requires three distinguishable
failures at sign-in: unreachable, not a Nextcloud instance, and no Mail app installed. Login
Flow v2 itself cannot produce the third one — `/index.php/login/v2` and its poll endpoint
are core Nextcloud routes that exist whether or not the Mail app is enabled, so a successful
poll proves nothing about the one app this client actually needs.

The only way to learn whether the Mail app is there is to ask it something, and the
cheapest thing to ask is the route [`smoke-auth.sh`](../../Scripts/smoke-auth.sh) already
uses as its own verdict: `GET /index.php/apps/mail/api/accounts`. A 404 there is
unambiguous — the route is not registered — versus a 401, which means the credential itself
is wrong and is a different failure this flow does not expect to see right after minting
that same credential.

This adds a request the brief's flow diagram in
[networking.md](../architecture/networking.md#the-flow) does not show: the documented four
steps are start, browser, poll, and the Keychain write. Reality needed a fifth, and
`networking.md` is corrected in this same change to say so.

## Decision

`LoginFlow.awaitCompletion()` calls `GET /index.php/apps/mail/api/accounts` with the app
password the poll just returned, immediately after a successful poll and before moving to
`.succeeded`. A 404 raises `LoginError.mailAppMissing` instead of returning credentials;
anything in `200...299` proceeds. The Keychain write happens after this, in the caller —
`LoginFlow` never writes it, so there is nothing to undo when this check fails.

Non-2xx, non-404 status codes on `/index.php/login/v2` itself (its first request) are
treated as `LoginError.notNextcloud` rather than a generic server error: a route that exists
on every Nextcloud instance answering with anything other than the documented JSON shape
means either this is not Nextcloud, or it is a version old enough that Login Flow v2 is not
registered — both read the same to a user typing a server address, so `notNextcloud` is a
single case rather than one per cause.

## Consequences

- Every successful sign-in costs one extra request. Negligible next to the browser
  round-trip a user is already waiting through.
- `mailAppMissing` is only reachable after a real app password already exists server-side.
  If the check fails, that password is still valid and still named **Nextcloud Mail
  (macOS)** in the user's security settings — it was never used again, but nothing revokes
  it. A user who fixes the Mail app installation and retries mints a second one. Acceptable
  for v1: multiple app passwords per device is exactly what the settings page is for.
- A server whose Mail app is present but returns something other than 200 or 404 (a 500, a
  502 from a misconfigured proxy) surfaces as `LoginError.server(status:)`, not
  `mailAppMissing` — the distinction the acceptance criteria ask for is specifically about
  absence, not general breakage.

## Alternatives considered

**Skip the check; let the mirror coordinator (WS-04) discover a missing Mail app later.**
Defers the third failure message past the point [S-01](../product/user-stories.md) requires
it — the user would see a successful sign-in and then a confusing, silent stall.

**A capabilities check instead of hitting the Mail API directly.**
`/ocs/v2.php/cloud/capabilities` was worth considering (`smoke-auth.sh` also calls it), but
it was not confirmed against the live server to name the Mail app deterministically the way
a direct 404 on the app's own route does, and adding an OCS-shaped request here would
duplicate parsing WS-02 already owns for that endpoint.

## Revisit when

WS-02's `MailClient` and `Endpoint` types exist and this call can move onto that seam
instead of a raw `URLSession` request — tracked as a request to WS-02 in the WS-01 report,
not a reason to change the behaviour now.
