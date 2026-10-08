<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Security model

*What we defend against, what we do not, and why. Stated plainly so that a user or a
Nextcloud reviewer can disagree with it on the facts.*

## Assets

1. The **app password** — full API access to the user's Nextcloud account.
2. The **mirror** — potentially every message the user has ever received.
3. The **session** — requests in flight.

## Threats we defend against

### Credential theft from the app

- The Nextcloud password is never entered into the app and never stored. Login Flow v2
  happens in the system browser ([ADR-0002](../decisions/0002-app-password-login-flow-v2.md)).
- The app password lives in the Keychain as `kSecClassInternetPassword`, keyed by host and
  login name, with `kSecAttrAccessibleAfterFirstUnlock`. Every item carries
  `kSecAttrSecurityDomain = com.nextcloud.mail.macos`, and every query filters on it: the
  login keychain is shared, and without that the app enumerated and tried to decrypt
  other apps' passwords ([ADR-0059](../decisions/0059-keychain-items-carry-a-security-domain.md)).
  It is never written to the database, to a log, or to a crash report.
- It is revocable server-side, per device, from the user's security settings, where it
  appears as **Nextcloud Mail (macOS)**.
- Sign-out deletes the Keychain item.

### Malicious message content

The largest attack surface in any mail client. Four layers, described in
[rendering.md](rendering.md):

1. The **server** sanitises HTML with HTMLPurifier before we ever see it, and rewrites
   remote images to a blocked placeholder.
2. **JavaScript is off** in the WebView.
3. A **content rule list** blocks every load except our own `ncmail:` scheme, so even a
   sanitiser bug cannot produce a network request.
4. **Navigation is cancelled** and links open in the browser, with a confirmation when the
   visible text and the target host disagree. The rule list does not see loads WebKit
   starts itself, so the body's context menu loses every item that would start one:
   Download Linked File and the Open … in New Window items
   ([ADR-0107](../decisions/0107-the-message-web-view-strips-loading-menu-items.md)).

We store sanitised HTML rather than raw MIME
([ADR-0009](../decisions/0009-sanitised-html-not-raw-mime.md)), so the dangerous form of a
message never reaches our disk at all.

### Tracking and IP leakage

- Remote content is blocked by default, per the server's transformation.
- Unblocking fetches through the server's **proxy** endpoint, so the user's IP is never
  exposed to the sender — the same property the web client has.
- Proxy responses are **not** stored ([ADR-0010](../decisions/0010-webview-scheme-handler.md)).
- The backfill never unblocks anything, so mirroring 40,000 messages fires zero tracking
  pixels. Mirroring is *more* private than reading in a browser, not less.

### Network attackers

- HTTPS with system trust evaluation. A bad certificate fails visibly; there is no "trust
  anyway" in v1.
- No certificate pinning: users self-host with every certificate arrangement imaginable,
  and pinning breaks them without stopping any attacker in this model.
- No cookies, ever ([networking.md](networking.md)). The only credential on the wire is the
  app password in the `Authorization` header.

### Other applications on the Mac

- App Sandbox with `com.apple.security.network.client` and
  `com.apple.security.files.user-selected.read-write`, nothing else. The second is what lets
  an explicit save panel open at all. Without it `NSSavePanel` logs "missing the User
  Selected File Read/Write app sandbox entitlement" and attachment saving silently did
  nothing. No file access outside the container except where the reader chose in that panel.
- Hardened runtime, Developer ID signature, notarization before any distribution.
- The database lives inside the container, so another sandboxed app cannot read it.

## Threats we do not defend against, and why

### An attacker with your unlocked Mac

They can read your mail. So can they in Mail.app, in a browser, and in Finder. A lock
screen is the control here, not a second password on one app.

### An attacker with your powered-off Mac and no FileVault

The mirror is plain SQLite in the sandbox container
([ADR-0006](../decisions/0006-data-at-rest.md)). With FileVault on — the default since
macOS 11 and effectively universal on managed fleets — the disk is encrypted and this is
covered. With FileVault off, a lifted disk yields the mail.

We chose this consciously:

- The alternative, SQLCipher, protects the database **only while the app is not running**
  and the key is not in memory. It does not protect against the unlocked-Mac case, which
  is the realistic one.
- The key would live in the Keychain, which the same attacker with the same disk and the
  same login password can open.
- It costs a C dependency, a custom GRDB build, key rotation, and a wipe path — real
  complexity for a narrow slice of risk that FileVault already covers.

**If Nextcloud requires encryption at rest for a supported client, this decision is the
first to revisit** — the ADR names the work. It is a defensible position, not a permanent
one.

### Malicious or compromised Nextcloud server

We trust the server. It has our mail. It sanitises our HTML. A compromised server can
serve us anything. Defending against it would mean client-side sanitisation and raw MIME
parsing, which trades a large new attack surface for a scenario in which the attacker
already has the mail.

### Physical keyloggers, screen recorders, malicious system extensions

Out of scope for any application.

## Data we never collect

No telemetry, no analytics, no crash reporting to a third party. If crash reporting is ever
added it is opt-in, self-hosted, and says so on the checkbox.

## Logging

- **Never logged:** passwords, tokens, `Authorization` headers, message bodies, subjects,
  addresses.
- **Logged at debug:** endpoint paths with ids, status codes, timings, queue depths.
- `OSLog` with `privacy: .private` on anything that could carry user data, which is the
  default for interpolated strings and must not be overridden to `.public` for
  convenience.
- A diagnostics export for bug reports includes counts and errors, never content, and
  shows the user what it contains before it is written.

## Review checkpoints

Three moments where someone reads this document again with the code in front of them:

1. **End of WS-01** — credential handling, before anything else is built on it.
2. **End of WS-09** — the WebView, the scheme handler, and the link-confirmation rule.
3. **Before any build leaves a developer's machine** — entitlements, hardened runtime,
   signing, and a grep for logged secrets.
