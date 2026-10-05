<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Nextcloud Mail for macOS

A native macOS client for [Nextcloud Mail](https://github.com/nextcloud/mail) and Contacts.
Local-first: your mail lives in a database on your Mac, so reading, search and triage all
work offline and the network only syncs.

![The main window: mailboxes in the sidebar, the message list, and an open message](docs/assets/main-window.png)

> **Not affiliated with Nextcloud.** This is an independent, unofficial client, not
> affiliated with or endorsed by Nextcloud GmbH. *Nextcloud* is a trademark of
> Nextcloud GmbH.

## Install

Download `NextcloudMail-<version>.dmg` from
[GitHub Releases](https://github.com/hamza221/nc-mac-mail/releases) and drag the app to
Applications. Release builds are not notarized yet, so the first launch needs
right-click → Open. Or build from source: see [Development](#development).

## Use

- Sign in with your Nextcloud server URL; the login finishes in your browser and the app
  keeps an app password in your Keychain.
- Everything is mirrored locally — read, full-text search and triage your mail offline;
  your actions queue up and sync back when you reconnect.
- Compose with send-later and undo send; drafts stay on the server.
- Contacts have their own section in the sidebar.
- Settings ▸ accounts, signatures, filters and app preferences.

The full specification — architecture, UX spec and every decision — is in
[docs/](docs/README.md); contributor conventions are in [AGENTS.md](AGENTS.md).

## Development

Xcode 26.6 (pinned in `.xcode-version`), which brings Swift 6.3.3. SwiftLint from Homebrew.
`swift format` is a subcommand of the toolchain, not a binary you install.

```sh
make setup       # resolve dependencies, check the tools are present
make build       # every package, warnings as errors
make test        # every package's tests
make build-app   # xcodebuild the app target
make app         # build it and launch it
make lint        # swift format --strict, then swiftlint --strict
make format      # apply formatting in place
```

Two toolchain traps, both already handled for you:

- **Prefer `make build-app` over bare `xcodebuild`, though both now work.** Until
  `NextcloudUI` 1e753cb, its manifest's `.treatAllWarnings(as: .error)` collided with the
  `-suppress-warnings` Xcode gives every package target, so bare `xcodebuild` and Cmd-B
  failed inside the library. Fixed upstream
  ([docs/feedback/library-feedback.md](docs/feedback/library-feedback.md)); the Xcode GUI
  builds this project.
- The Makefile passes `SUPPRESS_WARNINGS=NO`, because Xcode otherwise hides warnings in
  this project's own packages; two GRDB warnings come along as the price
  ([ADR-0016](docs/decisions/0016-warnings-as-errors-at-the-build-command.md)).

The committed project signs ad hoc so it builds on any Mac and on CI with no Apple
account; for a locally signed build and the sandbox details, see
[ADR-0018](docs/decisions/0018-ad-hoc-signature-in-the-checked-in-project.md).

### Releasing

Push a tag `v<version>` (or run the **Release** workflow by hand with a tag) and
`.github/workflows/release.yml` builds Release on a macOS runner, packages
`NextcloudMail-<version>.dmg` with `Scripts/make-dmg.sh` — styled background, app icon
next to an `/Applications` drop link — and publishes a GitHub release with the DMG
attached and generated notes. The same script runs locally:

```sh
brew install create-dmg
Scripts/make-dmg.sh            # writes build/NextcloudMail-<version>.dmg
```

With no secrets configured the app inside the DMG is ad-hoc signed (ADR-0018), so
Gatekeeper on another Mac requires right-click → Open, and notarization is a manual
follow-up. To turn real signing on, no workflow edit is needed: set the repository
secrets `MACOS_CERT_P12` (base64 Developer ID certificate), `MACOS_CERT_PASSWORD`,
`APPLE_TEAM_ID`, and for notarization `NOTARY_APPLE_ID` plus `NOTARY_PASSWORD`
(an app-specific password); the import, sign, notarize and staple steps activate
when they exist.

## Licence

AGPL-3.0-or-later, matching Nextcloud Mail and `NextcloudUI`.
