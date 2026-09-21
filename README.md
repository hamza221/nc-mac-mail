<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Nextcloud Mail for macOS

A native macOS client for [Nextcloud Mail](https://github.com/nextcloud/mail), built
against [`NextcloudUI`](https://github.com/hamza221/nextcloud-swiftui) — and built to
answer the question that package's roadmap ends on: *what does a real client need that
the library does not yet give it?*

**v1 is read and triage, over a complete local mirror of your mail.** You log in, the app
downloads your mailboxes in the background, and from that moment every list, every
message and every search is answered from disk. The network exists to fill the database
and to carry your actions back to the server. It is never on the path between you and a
message you already have.

No composer in v1. That is [ADR-0012](docs/decisions/0012-read-and-triage-scope.md).

## This repository, right now

The skeleton is in: an Xcode project that builds an empty three-column app, five Swift
packages that build and test on their own, lint and CI. There is no product code yet. What
came before it, and still carries the weight, is a specification complete enough that
separate agents can implement separate parts of it without talking to each other, and have
the parts fit.

| If you are… | Start at |
| --- | --- |
| A person, deciding whether this is the right product | [docs/product/overview.md](docs/product/overview.md) |
| An agent, about to be assigned work | [docs/delivery/workstreams.md](docs/delivery/workstreams.md) → your brief in [docs/delivery/briefs/](docs/delivery/briefs/) |
| Looking for why something is the way it is | [docs/decisions/](docs/decisions/README.md) |
| Implementing the cache | [docs/architecture/local-mirror.md](docs/architecture/local-mirror.md) + [docs/reference/schema.sql](docs/reference/schema.sql) |
| Wiring a screen | [docs/product/ux-spec.md](docs/product/ux-spec.md) + [docs/reference/ui-components.md](docs/reference/ui-components.md) |
| Calling the server | [docs/reference/api-payloads.md](docs/reference/api-payloads.md) + [plan/API.md](plan/API.md) |

The full map is [docs/README.md](docs/README.md). Conventions every agent follows are in
[AGENTS.md](AGENTS.md).

## The shape of it

```
┌────────────────────────────────────────────────────────────────┐
│  NextcloudMail.app          SwiftUI views, @Observable stores  │
│                             NextcloudUI for every Nextcloud    │
│                             surface: avatars, rows, chips      │
├────────────────────────────────────────────────────────────────┤
│  NCMailSync    mirror + backfill + incremental sync + the      │
│                offline mutation queue. Writes the database,    │
│                never the screen.                               │
├────────────────────────────────────────────────────────────────┤
│  NCMailStore   GRDB over SQLite. The single source of truth    │
│                for reads. Observation pushes changes to views. │
├────────────────────────────────────────────────────────────────┤
│  NCMailNet     URLSession, app-password auth, typed endpoints  │
│  NCMailCore    value types, decoding, mailbox tree, no I/O     │
└────────────────────────────────────────────────────────────────┘
```

One invariant holds the design together, and every workstream is written against it:

> **The network never renders. The network only writes to the database.**

A view that reaches for `URLSession` is a bug, not a shortcut. Everything that follows —
offline reading, instant lists, local full-text search, triage on a train — falls out of
that one rule. It is written up in [ADR-0003](docs/decisions/0003-local-first-full-mirror.md).

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

**Build the app with `make build-app`, not with bare `xcodebuild`.** `NextcloudUI`'s
manifest sets `.treatAllWarnings(as: .error)`, Xcode gives every package target
`-suppress-warnings`, and swiftc refuses the two together. The Makefile passes
`SUPPRESS_WARNINGS=NO`, which is the only place the override can go. The same flaw means
**the Xcode GUI cannot build this project yet** — there is nowhere to put the override in a
Cmd-B. It is filed against the library in
[docs/feedback/library-feedback.md](docs/feedback/library-feedback.md) and recorded in
[ADR-0016](docs/decisions/0016-warnings-as-errors-at-the-build-command.md).

### Sandbox, signing and the Keychain

The App Sandbox is **on in every configuration**, with
`com.apple.security.network.client` and nothing else. Nobody needs to turn it off: WS-00
measured an ad-hoc signed, sandboxed bundle on macOS 26 and `SecItemAdd`,
`SecItemCopyMatching` and `SecItemDelete` all returned `errSecSuccess`, running inside the
container.

The committed project signs ad hoc (`CODE_SIGN_IDENTITY = "-"`) so that it builds on any
Mac and on CI with no Apple account. One consequence: Xcode prints
`note: Disabling hardened runtime with ad-hoc codesigning`, so a local build is **not**
hardened even though `ENABLE_HARDENED_RUNTIME = YES` is set. For a locally signed build:

```sh
xcodebuild -project NextcloudMail.xcodeproj -scheme NextcloudMail SUPPRESS_WARNINGS=NO \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_IDENTITY="Apple Development" build
```

[ADR-0018](docs/decisions/0018-ad-hoc-signature-in-the-checked-in-project.md) has the rest.

## Status

| | |
| --- | --- |
| **Decided** | Product scope, architecture, cache design and schema, sync protocol, offline queue, rendering and security model, 16 workstreams with agent briefs |
| **Built** | WS-00: Xcode project, five packages, Makefile, lint, CI, REUSE |
| **Next** | WS-01/02 (auth, HTTP) → WS-03 (store). See [docs/delivery/roadmap.md](docs/delivery/roadmap.md) |
| **Not started** | All product code |

## Prior art in this repo

`plan/` holds the three briefs this work started from: the Mail API map, the Vue client's
feature list, and the original macOS client plan. They are inputs, kept as written. Where
a living document disagrees with them, the living document wins and says so — the largest
case being the local mirror, which reverses `plan/macos-client.md`'s "No local database".

## Licence

AGPL-3.0-or-later, matching Nextcloud Mail and `NextcloudUI`.
