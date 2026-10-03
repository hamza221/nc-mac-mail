<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0059: Keychain items carry a security domain, and every query filters on it

**Status:** Accepted
**Date:** 2026-10-03
**Decided by:** first manual QA pass, after launch asked for a GitHub password and never
offered sign-in

## Context

`Keychain.allAccounts()` queried `kSecClassInternetPassword` with no other attribute. On
macOS the login keychain is shared between apps, and a sandboxed, ad-hoc signed app can read
other items' *attributes* without consent, so that query returned every internet password on
the Mac. On the tester's machine that included git's credential-helper item for
`https://github.com`, account `hamza221`.

Two failures came out of that one query:

1. `AppSession.init()` counted it as a stored account, so `needsSignIn` was false and the
   login screen never appeared.
2. `AppSession.start()` then called `Keychain.load` on it, which decrypts, and macOS asked
   the user to let Nextcloud Mail read their GitHub password.

When the prompt was denied, `start()` kept `hasStoredAccounts` true, which left a window
with no account and no way to sign in.

`baseQuery` had a quieter version of the same flaw. An internet password's uniqueness key is
server, account, protocol, port, path, security domain and authentication type. A browser
item saved for a Nextcloud instance's web login (same host, same user name) matched our
query, so `load` would have returned the web password and `save`'s delete-then-add would
have deleted it.

## Decision

Every item this app writes carries `kSecAttrSecurityDomain = "com.nextcloud.mail.macos"`.
`baseQuery` (save, load, delete) and `allAccounts()` include that attribute.

Separately, `AppSession.start()` sets `hasStoredAccounts` from the accounts it actually
loaded, so an item whose consent prompt is denied leads to the sign-in screen.

## Consequences

- Other apps' internet passwords are invisible to the app: never listed, decrypted, or
  deleted.
- Items written before this change have no security domain, so they are no longer found.
  Anyone who signed in on an earlier build signs in once more. The old item stays in the
  keychain until it is removed in Keychain Access. It can't block the new one, because
  security domain is part of the uniqueness key.

## Alternatives considered

**`kSecAttrLabel` or `kSecAttrComment` as the marker.** Either filters `allAccounts()`, but
neither is part of the uniqueness key. `SecItemAdd` would then fail with
`errSecDuplicateItem` against a browser item for the same host and user, and an unfiltered
delete would remove it.

**`kSecUseDataProtectionKeychain`.** This scopes items to the app's access group properly,
but it needs an application identifier, which an ad-hoc signature with no team does not have
([ADR-0018](0018-ad-hoc-signature-in-the-checked-in-project.md)). Worth revisiting with a
Developer ID build.

**`kSecAttrCreator`.** It works for filtering, but it is not part of the uniqueness key
either, and it is a FourCharCode no one reads.

## Revisit when

The project signs with a team identity. At that point the data-protection keychain becomes
possible, and it scopes items by the OS rather than by convention.
