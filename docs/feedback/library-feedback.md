<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# NextcloudUI feedback

*The deliverable `hamza221/nextcloud-swiftui`'s README is waiting for: "Build a real Mail
client against it, and freeze the API on what that finds."*

**Append as you go.** Every workstream adds what it found, or says "nothing new" in its
report and means it. WS-15 curates this into something a maintainer can act on.

Entry format — an entry without a call site is an opinion, not evidence:

```markdown
### Short title
**Workstream:** WS-NN · **Component:** `NCThing` · **Severity:** blocker | friction | polish
**Where:** path/to/File.swift:123
What happened. What we did instead. What would have been better.
```

---

## Status

Seeded from the design pass, before implementation. Everything below is either a fact about
the library as it stands or a question the design could not answer from the outside — the
answers arrive as workstreams land.

## Missing icons

**Workstream:** design pass · **Component:** `NCSymbolCatalog` · **Severity:** friction
**Where:** `Sources/NextcloudIcons/NCSymbolCatalog.swift` (91 symbols)

A mail client's chrome needs roughly ten Material Design Icons the catalogue does not carry:

| Needed for | MDI name |
| --- | --- |
| Inbox mailbox | `inbox` |
| Sent mailbox | `send` |
| Drafts mailbox | `file-document-outline` |
| Archive action and mailbox | `archive-arrow-down-outline` |
| Attachment indicator | `paperclip` |
| Mark unread | `email-open-outline` |
| Refresh / syncing | `sync` |
| Tags | `tag-outline` |
| Answered indicator | `reply` |
| Snooze (v1.1) | `alarm` |

Present and used already: `email`, `folder`/`folderOutline`, `star`/`starOutline`,
`delete`/`deleteOutline`/`trashCanOutline`, `alertOctagonOutline` (junk), `magnify`,
`clockOutline`, `download`/`trayArrowDown`, `openInNew`, `dotsHorizontal`, `chevron*`.

The client substitutes SF Symbols behind a single `MailSymbol` type (WS-13), so the swap is
mechanical when the catalogue grows. This is the most concrete input available to the
roadmap's open question, "which ~150 icons to curate": the Mail floor is these ten on top
of the 91.

## Composition gaps

### A list row has one leading slot; a mail row wants two
**Workstream:** design pass · **Component:** `NCListItem` · **Severity:** friction
**Where:** `Sources/NextcloudUI/Components/ListItem/NCListItem.swift:79`

A mail row is: [unread dot | star | attachment clip] [avatar] [sender / subject] [date /
count]. `NCListItem` gives one `leading` slot, so the accessory column goes inside it as an
`HStack` and loses the component's alignment and spacing discipline. Rows with and without
accessories then drift unless the app re-imposes a fixed width itself.

Either a second slot, or a documented pattern for the accessory column. Mail, Files
(sync badges) and Talk (unread/mention markers) all want the same shape, which suggests it
belongs in the library rather than in three apps.

### There is no message-header block
**Workstream:** design pass · **Severity:** polish

Sender, recipients, date and an actions row is a shape every mail client has, and the app
builds it from `NCUserBubble` + `NCChip` + `Text`. Worth asking whether it generalises
(Talk has a message header too, Files has a file header) or whether it is Mail-specific and
belongs here.

## Questions the showcase cannot answer

Each of these is answered by a workstream, and the answer belongs here either way.

1. **`NCListItem` at 50,000 rows** (WS-08) — does the optional-slot `HStack` stay cheap in a
   `List`, or does a mail list need a cheaper row?
2. **Unread weight versus selection tint** (WS-08) — does `.fontWeight(.semibold)` still
   read as unread when the row is selected and tinted by the brand colour?
3. **Brand tint in a three-column split view** (WS-13) — `.ncTheme` sets `.tint` globally,
   overriding the user's macOS accent. Right for a mail client, or is
   `NCAccentPolicy.brandSurfacesOnly` the better default here?
4. **MDI glyphs in a signed Release build** (WS-13) — `NCIcon.rendersBundledAssets` is known
   true under Xcode run. Nobody has checked a sandboxed, hardened, signed build, and
   [ADR-0001](../decisions/0001-xcode-project-in-git.md) assumes it.
5. **`NCRelativeDateFormatter` for a mail list** (WS-08) — is the short form right ("3m",
   "Yesterday", "12 Mar"), or does a mail list want its own rules?
6. **`NCAvatar`'s loader and a database-backed cache** (WS-08) — the loader signature
   assumes fetching. Ours reads the mirror first. Does the library's own `NCImageCache`
   duplicate work, or compose cleanly?

## Things that worked

Kept deliberately: a feedback document that only complains is not evidence.

- **The loader closure instead of `AsyncImage`.** The library bans `AsyncImage` because it
  uses `URLSession.shared` and Nextcloud avatars need auth. That is exactly right, and it
  is what lets this app serve avatars from the mirror with no library change — the
  component never knows the difference.
- **Non-optional `NCAccessibilityLabel`.** Unlabelled construction does not compile, which
  means the app cannot accumulate unlabelled controls the way it otherwise would.
- **`NCTheme` reassignment recolours the running app.** Exactly one line after the
  capabilities call.
- **Not building `NCEmptyContent` and `NCSettingsSection`.** `ContentUnavailableView` and
  `Form(.grouped)` are what this app uses, and the DocC notes explaining why are the right
  kind of documentation.
- **The `MailScreenDemo` in the showcase** is a genuinely useful reference composition — it
  is what the sidebar and list briefs point at.

---

## From WS-00 (project skeleton)

### `.treatAllWarnings(as: .error)` makes the library unbuildable from Xcode
**Workstream:** WS-00 · **Component:** `Package.swift` · **Severity:** blocker
**Where:** `Package.swift:19` (`sharedSwiftSettings`), every target

Any Xcode project that depends on `NextcloudUI` fails to build, before compiling a line of
its own code:

```
error: conflicting options '-warnings-as-errors' and '-suppress-warnings'
error: Conflicting options (in target 'NextcloudDesign' from project 'nextcloud-ui-swift')
** BUILD FAILED **
```

Xcode gives every package target `-suppress-warnings`, so a dependency's warnings stay out
of the consumer's issue navigator. `.treatAllWarnings(as: .error)` produces
`-warnings-as-errors`. swiftc rejects the pair. Xcode 26.6 (17F113), Swift 6.3.3.

What makes it a blocker rather than friction is where the override can go. `xcodebuild
SUPPRESS_WARNINGS=NO` on the command line works, because a command-line setting reaches the
synthesised package projects. `SUPPRESS_WARNINGS = NO` in the consumer's `.xcodeproj` does
not — checked at project level, no effect. So there is no fix a consumer can commit, and
**Cmd-B in the Xcode GUI cannot be made to work at all** while the setting is in the
manifest. This app builds only through `make build-app`, which adds the override.

The library's own CI never sees it: it runs `swift build`, where SwiftPM applies no
suppression to the root package.

Suggested fix: drop `.treatAllWarnings(as: .error)` from the manifest and pass
`-Xswiftc -warnings-as-errors` from the `Makefile` and CI instead. SwiftPM applies
`-Xswiftc` to the root package's own targets and not to its dependencies, so the coverage is
identical and consumers are unaffected. That is what this repo now does; ADR-0016 has the
measurements. The library also has a `Showcase/**/*.pbxproj` glob in its `REUSE.toml` with
no project behind it — the moment that project exists, its own build will hit this.

### `.ncTheme(.nextcloud)` at a scene root is one line and it works
**Workstream:** WS-00 · **Component:** `NCTheme` · **Severity:** polish
**Where:** `NextcloudMail/App/NextcloudMailApp.swift:19`

The skeleton's three columns wear the brand colour with a single modifier on the
`WindowGroup` content and `@Environment(\.ncTheme)` in the column view. No setup, no
injection, no `@StateObject`. `NCDynamicColor` conforming to `ShapeStyle` means
`.foregroundStyle(theme.colors.primary)` composes with no unwrapping. Nothing to report
beyond that it was uneventful, which is the point of a token system.

### Icons compile under Xcode, as ADR-0001 assumed
**Workstream:** WS-00 · **Component:** `NextcloudIcons` · **Severity:** —
**Where:** build log, target `nextcloud-ui-swift_NextcloudIcons`

`actool` runs and emplaces `Assets.car` in the resource bundle:
`note: Emplaced .../nextcloud-ui-swift_NextcloudIcons.bundle/Contents/Resources/Assets.car`.
That is the premise of [ADR-0001](../decisions/0001-xcode-project-in-git.md) confirmed for
an unsigned debug build. Question 4 in the list above — whether the glyphs survive a
sandboxed, hardened, signed Release build — is still open and still WS-13's.
