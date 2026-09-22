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

---

## From WS-01 (login flow, Keychain, session)

Nothing new. `NCButtonStyle` (`.primary`, `.tertiary`), `NCNoteCard(.error, title:, message:)`
and `NCProgressStyle.normal` covered `LoginView` exactly as
[ui-components.md](../reference/ui-components.md) describes them — a server field, a
Continue button, a waiting state and an error banner needed no workaround and no custom
view. `.ncAccessibilityLabel(.text(...))` labelled the plain `TextField` and `ProgressView`
this screen uses that are not library components themselves, which is not something the
component map called out but worked exactly like the library's own controls.

One thing worth recording precisely because it is not a complaint: `LoginView` is not yet
reachable from the running app. `RootSplitView` is still WS-00's three-column placeholder,
and wiring a sign-in screen in ahead of it belongs to WS-13, not to this workstream — see
"For the next workstream" in the WS-01 report.

---

## From WS-02 (HTTP client, endpoints, models, decoding)

Nothing new about `NextcloudUI`: this workstream builds no view and imports no library
component. What it has instead is feedback about the packaging of this repository's own
test-support package and about the Mail server's JSON, so it is recorded here rather than
lost.

### `NCMailTestSupport` cannot be used by the tests it was created for
**Workstream:** WS-02 · **Component:** `Packages/NCMailTestSupport/Package.swift` · **Severity:** blocking, worked around

The package depends on `NCMailCore`, `NCMailNet` and `NCMailStore`, so none of their test
targets can depend on it: SwiftPM rejects the cycle. `Bundle.module`, which
[testing-strategy.md](../delivery/testing-strategy.md) tells every package to load fixtures
through, is therefore reachable only from `NCMailTestSupportTests`.

WS-02 works around it by resolving the fixture directory from `#filePath`
([ADR-0022](../decisions/0022-fixtures-by-path-not-bundle.md)). The fix is to make the
fixture-vending part a leaf: either drop the three dependencies from `NCMailTestSupport`, or
add a `NCMailFixtures` target inside it with no dependencies and let `FakeTransport` depend
on that. WS-14 and WS-00 own the change between them.

### `swift format` disagrees with `#expect` about trailing closures
**Workstream:** WS-02 · **Component:** toolchain, Swift Testing · **Severity:** polish

`#expect(list.allSatisfy(\.isSelectable))` does not compile: the macro expands the key path
into a position where the `rethrows` overload is selected and the call is not marked `try`.
`#expect(list.allSatisfy { $0.isSelectable })` is fine. Worth knowing before the third time
it happens.

`Testing.Tag` also collides with this project's `Tag` model, so a test that names the model
in a type annotation has to qualify it as `NCMailCore.Tag`.

### The Mail server's JSON needs a lenient decoder in four specific places
**Workstream:** WS-02 · **Component:** `nextcloud/mail` 5.12.0-rc.1 · **Severity:** upstream

Each is documented and corrected in
[api-payloads.md](../reference/api-payloads.md), and each is a decoding failure for anyone
who writes the obvious `Codable` conformance. An empty `tags` dictionary serialises as `[]`
rather than `{}`; `mentionsMe` is `0`/`1` rather than a boolean; `specialRole` is the
integer `0` when there is no special use; and an unknown id answers 403 with a body of `[]`
rather than the documented error envelope. The first two are PHP's array/object ambiguity
reaching the wire, and both would be fixed upstream by casting at the point of
serialisation. WS-15 should decide whether any of it is worth an issue against
`nextcloud/mail`.

---

## From WS-03 (GRDB stack, schema, migrations, DAOs)

Nothing new about `NextcloudUI`. This workstream is `NCMailStore`, which by
[ADR-0013](../decisions/0013-module-layout.md) must not import SwiftUI at all, so it never
touched a component. The three things worth writing down are about GRDB and SQLite, and the
first two cost a working day between them.

### SQLite's update hook skips `WITHOUT ROWID` tables, so `ValueObservation` never fires
**Workstream:** WS-03 · **Component:** GRDB `ValueObservation` · **Severity:** trap
**Where:** `docs/decisions/0025-rowid-tables-for-anything-observed.md`

`ValueObservation` is built on `sqlite3_update_hook`, and
[SQLite does not call that hook for `WITHOUT ROWID` tables](https://www.sqlite.org/c3ref/update_hook.html).
An observation of such a table delivers its first value and then waits forever. No error, no
warning, no timeout — the first symptom was a test that hung. Four tables in `schema.sql` were
`WITHOUT ROWID` and three of them were things a view would want to watch.

Worth an upstream note: GRDB could detect this at observation start, when it already resolves
the tracked region against the schema, and trap with "cannot observe WITHOUT ROWID table
`avatar`". The information is all there and the failure mode is silence.

### FTS5 virtual tables reject `ON CONFLICT`, so there is no upsert
**Workstream:** WS-03 · **Component:** SQLite FTS5 · **Severity:** friction

`messageSearch` is written from two places: an envelope supplies subject, preview and people,
a body supplies the text. Neither may clobber the other's columns, and there is no
`INSERT … ON CONFLICT DO UPDATE` on a virtual table to express that. The shape that works is
`UPDATE …; if changesCount == 0 { INSERT … }`, which reads like a mistake until you know why.
It is in `SearchIndexWriter` with a comment, and WS-11 will read that file before it writes a
query.

### An index helps only if the predicate lets the planner choose it
**Workstream:** WS-03 · **Component:** SQLite query planner · **Severity:** —

The threaded list took 196 ms for its first fifty rows out of fifty thousand, against 0.5 ms
for the flat one. Nothing was missing: `idxMessageThread` existed and the plan used it for two
of the three subqueries. The unread count was written
`count(*) … WHERE mailboxId = ? AND threadRootId = ? AND isSeen = 0`, and that third term made
`idxMessageMailboxSeen` look attractive, so the planner took it — matching every unread message
in the mailbox and filtering by thread afterwards. Rewriting it as
`sum(CASE WHEN isSeen THEN 0 ELSE 1 END)` over the same two-column predicate took it to 0.8 ms.

Recorded here because the lesson generalises past this query: `EXPLAIN QUERY PLAN` saying
"uses an index" is not the assertion worth making. Which index, and over how many rows, is.
