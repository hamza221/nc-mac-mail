<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0108: In-app updates use Sparkle 2, outside NCMailNet, with a stable and a beta channel

**Status:** Accepted
**Date:** 2026-10-08
**Decided by:** the maintainer, choosing between Sparkle and an in-house GitHub Releases
check; built and checked against a notarized Developer ID build

## Context

Releases are notarized DMGs on GitHub. Without an updater, nobody running the app learns
that a new version exists, and every beta tester stays on whatever they downloaded first.

Updating the app has three parts: finding a newer release, proving the download is ours,
and replacing a running sandboxed app bundle. The third part needs a process outside the
sandbox. Sparkle 2 does all three, and it is what nearly every macOS app outside the App
Store uses.

Sparkle makes its own network requests and puts its own windows on screen. That breaks
two house rules: "no network call outside `NCMailNet`" and "the network only writes to the
database".

## Decision

- **Sparkle 2** (SPM, `upToNextMajorVersion` from 2.10.0), linked into the app target
  only. `AppUpdater` wraps `SPUStandardUpdaterController` and is the only type that
  imports Sparkle.
- **The exception is deliberate, and it is limited to the updater.** The two rules exist
  to protect mail: offline reading, and views that never wait on a request. The updater
  handles no mail, no credentials and no account state. It has to keep working when the
  mirror is broken, which is when an update is most needed, so its state does not belong
  in the database. Sparkle's requests carry no user data. System profiling stays off,
  which is Sparkle's default.
- **Feed.** `appcast.xml` at the repository root, read from
  `raw.githubusercontent.com/hamza221/nc-mac-mail/main/appcast.xml` (`SUFeedURL`). The
  path is a public contract. `Scripts/release.sh` writes each item only after the DMG it
  names has been uploaded.
- **Trust.** Every enclosure carries an EdDSA signature (`SUPublicEDKey`; the private key
  is in the release manager's Keychain under account `nc-mac-mail`). Sparkle also requires
  the new app's Developer ID signature to match the running app's.
- **Channels.** Pre-release items are tagged `<sparkle:channel>beta</sparkle:channel>`.
  Stable items are untagged. `allowedChannels(for:)` returns `["beta"]` on the beta
  channel and nothing on stable. A build whose version has a pre-release suffix starts on
  beta, and the choice is a setting.
- **Notification.** Scheduled checks run daily (`SUEnableAutomaticChecks`). If one finds
  an update while the app is not in focus, Sparkle uses gentle reminders: the sidebar
  shows "Version X is available" with an Update button instead of a window taking focus.
  App ▸ Check for Updates… and Settings ▸ General ▸ Updates cover the rest.
- **Release notes are Markdown** (`sparkle:format="markdown"`). Sparkle renders HTML notes
  in a `WKWebView`, which `rendering.md` keeps for message bodies. Markdown notes are
  drawn natively.
- **Sandbox.** `SUEnableInstallerLauncherService` plus a temporary mach-lookup exception
  for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`. The downloader service is not
  needed because the app already has `network.client`.
- **Signing.** Sparkle's helpers ship ad-hoc signed. `make-dmg.sh` re-signs them from the
  inside out with the release identity, then re-signs the app.
- **Releases are cut locally** with `Scripts/release.sh`. A tag push no longer publishes
  from CI: the CI build cannot sign the update, and if it replaced the asset after the
  feed was written, the EdDSA signature would no longer match and every update to that
  version would fail. `release.yml` now only builds the DMG on request and keeps it as a
  workflow artifact.
- Debug builds and test hosts never start the updater.

## Consequences

- Users get a native update window with release notes, plus download, install and
  relaunch.
- A third-party binary framework, with its own XPC services, now runs in the app.
- There are now two network stacks. `security.md`'s "no network outside NCMailNet" rule
  has one documented exception.
- Losing the EdDSA private key means no signed update can be published to anyone running
  a build with this public key. Back up the key with `generate_keys --account nc-mac-mail
  -x <file>`.
- Releases depend on one machine, the one holding the signing identity, the notary
  profile and the EdDSA key.
- `CURRENT_PROJECT_VERSION` must go up with every release, because Sparkle compares
  `CFBundleVersion`. `release.sh` refuses to release if it has not.
- 0.3.0-beta and earlier have no updater, so their users have to download the first
  Sparkle build themselves.

## Alternatives considered

- **In-house check through `NCMailNet`.** Poll the GitHub Releases API, write the result
  to the store, and show a banner whose button downloads the DMG. This follows both
  rules, but it cannot install: a sandboxed app cannot replace itself, so users would
  still drag the app to Applications. Rejected by the maintainer in favour of real
  updates.
- **Feed as a release asset** (`releases/latest/download/appcast.xml`). GitHub's "latest"
  skips pre-releases, so the beta channel could never see a release. Rejected.
- **Separate feeds per channel.** Sparkle 2's channels do the same thing with one file and
  no per-channel feed URL to keep in sync. Rejected.
- **Publishing from CI.** This needs the EdDSA private key, the Developer ID certificate
  and notary credentials as repository secrets. It is possible, but none of those secrets
  exist today, and the local script works now. Revisit below.

## Revisit when

- The signing identity, notary credentials and EdDSA key move into CI secrets. At that
  point `release.sh`'s steps can move into `release.yml` unchanged.
- The app ships through the Mac App Store, which forbids Sparkle.
