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

**Resolved, 2026-09-22.** Fixed upstream exactly as suggested and merged as
[`1e753cb`](https://github.com/hamza221/nextcloud-swiftui/pull/2): the manifest no longer
sets `.treatAllWarnings(as: .error)`, and the `Makefile` and CI pass
`-Xswiftc -warnings-as-errors` instead. Verified from this side against the merged commit —
bare `xcodebuild -scheme NextcloudMail build` succeeds with no override, so **the Xcode GUI
builds this project**. The `Showcase/**/*.pbxproj` glob was left alone deliberately, to
keep the fix to one thing; it is still dead and still waiting for the project behind it.

Worth recording as process rather than as a bug: this is the first piece of feedback from
this project to complete the round trip. WS-00 hit it on day one, could not work around it
from the consumer side, wrote it down here instead of absorbing it, and the fix came back.
The reason it survived the library's own CI is the part worth keeping — `swift build` never
passes `-suppress-warnings`, and neither does `xcodebuild` when the package is the *root*.
The flag only appears when the package is a dependency of another project's target, which
no job in the library exercised. A library cannot catch this class of bug by building
itself.

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

---

## From WS-13 (app shell, theme, restoration, status)

### Question 4 answered: MDI glyphs do survive a signed, sandboxed Release build
**Workstream:** WS-13 · **Component:** `NCIcon.rendersBundledAssets` · **Severity:** —

`xcodebuild -configuration Release SUPPRESS_WARNINGS=NO build` produces a signed, hardened
`NextcloudMail.app`
(`codesign -dv` reports `flags=0x10002(adhoc,runtime)`), and its
`nextcloud-ui-swift_NextcloudIcons.bundle/Contents/Resources/Assets.car` still carries every
generated symbol — `assetutil --info` lists 1,566 `"Name"` entries in that one catalogue,
including the four `MailSymbol` cases (`.junk`, `.trash`, `.folder`, `.star`) that resolve to
a bundled asset rather than an SF Symbol fallback. [ADR-0001](../decisions/0001-xcode-project-in-git.md)'s
assumption holds for Release as well as Debug. Not run under an actual `open`ed window in
this environment — no GUI, no `screencapture` — so this is evidence from the build product,
not a screenshot.

### Question 3 answered, provisionally: `.ncTheme` setting `.tint` globally reads right for a
mail client, with one open edge
**Workstream:** WS-13 · **Component:** `NCAccentPolicy` · **Severity:** —

Nothing in the shell fought the brand tint driving selection and focus — a `NavigationSplitView`
with three placeholder columns has no competing accent, so this is not yet tested against a
real message list's selection highlight (WS-08's question, not this workstream's). Kept at
the default `.instance` policy; no evidence surfaced that a mail client specifically wants
`.brandSurfacesOnly`.

### `MailSymbol` was built exactly to the design pass's list
**Workstream:** WS-13 · **Component:** `NCSymbolCatalog` · **Severity:** —
**Where:** `NextcloudMail/MailSymbol.swift`

The nine missing-icon cases (`inbox`, `sent`, `drafts`, `archive`, `attachment`, `unread`,
`sync`, `tag`, `answered`) and the four already-catalogued ones (`junk`, `trash`, `folder`,
`star`) match the "Missing icons" table above one for one. Nothing new to add; recorded here
only to close the loop the design pass opened.

### The brand colour assumes one instance; multi-account has no rule for two
**Workstream:** WS-13 · **Component:** app-level, not a library gap · **Severity:** friction
**Where:** `NextcloudMail/App/AppSession.swift`, `refreshTheme()`

[S-09](../product/user-stories.md#s-09-it-looks-like-the-instance-it-belongs-to-ws-13) and
`ui-components.md`'s theme section both write as if there is one server. WS-07's brief
promises multi-account, each with its own mailbox tree, and nothing in the product
specification says whose brand colour wins when two accounts are on different Nextcloud
instances with different colours. `AppSession` picks the first account in a stable
(server, login name) sort, which is deterministic but arbitrary — not a considered answer.
This is a product question for `docs/product/ux-spec.md`, not a `NextcloudUI` gap, so it is
recorded here rather than filed against the library.

### Nothing new from `NextcloudUI` — WS-04 draws nothing
**Workstream:** WS-04 · **Component:** — · **Severity:** —

The mirror is an actor in `NCMailSync` with no view, no symbol and no colour, so it never
touched the library. Recorded rather than left blank, because "nothing new" is only an
acceptable answer if somebody checked.

### `MailStore` cannot write a page and its cursor in one transaction from outside
**Workstream:** WS-04 · **Component:** `NCMailStore`, not `NextcloudUI` · **Severity:** friction
**Where:** `MailStore.upsert(envelopes:)`, `MailStore.setEnvelopeCursor(_:complete:mailboxId:lastSyncAt:)`

`local-mirror.md` asked stage 1 for one transaction over both.
`upsert(envelopes:)` opens its own, and the pieces it uses — `SearchIndexWriter`,
`EnvelopeWrite.indexedPeople` — are internal to the package, so a caller cannot reproduce
the page write inside its own `store.write { }` without reimplementing the address rewrite
and the FTS row from outside the module that owns them.

Resolved by ordering rather than by a new method
([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)): envelopes commit first, the
cursor second, and a crash between them re-reads one page. Noted here because the next
workstream to want two store calls atomic will hit the same wall, and because
`upsert(envelopes:cursor:complete:mailboxId:)` is a small addition if WS-03 would rather
have it than the ordering argument.

### `mailbox.lastPrimedAt` has no DAO, so stage 0 writes it in raw SQL
**Workstream:** WS-04 · **Component:** `NCMailStore` · **Severity:** friction
**Where:** `MirrorCoordinator.storePrimed(_:mailboxId:)`

`MailboxWrite` correctly omits every mirror-bookkeeping column (ADR-0023), and
`setEnvelopeCursor` covers `envelopeCursor`, `envelopesComplete`, `lastSyncAt`,
`syncFailureCount` and `lastSyncError` — but nothing covers `lastPrimedAt`, which stage 0
is the only writer of. It is set through `store.write { }` with a one-line `UPDATE`, which
works and is the documented escape hatch, but it is `NCMailSync` naming a column in another
package's table. `setPrimed(mailboxId:at:)` next to `setEnvelopeCursor` would close it.

### `mailbox.lastPrimedAt` now has a DAO
**Workstream:** wave-2 fixes · **Component:** `NCMailStore` · **Severity:** resolved
**Where:** `MailStore.setLastPrimedAt(_:mailboxId:)`

WS-04's entry above asked for `setPrimed(mailboxId:at:)` next to `setEnvelopeCursor`. It
exists as `setLastPrimedAt(_:mailboxId:)`, and `MirrorCoordinator.storePrimed` uses it.
This was not a courtesy: `MailStore.read`/`write` are internal now
([ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md)), so the raw-SQL
escape hatch WS-04 used is gone and the DAO had to exist for the coordinator to compile.
The general form of WS-04's other entry stands — a caller outside the package that wants
two store calls in one transaction still cannot have one.

### Nothing new from `NextcloudUI` — the wave-2 fixes draw nothing
**Workstream:** wave-2 fixes · **Component:** — · **Severity:** —

Both changes are below the view layer: a package boundary and a schema. No view, no symbol,
no colour, and `NextcloudMail/**` changed by nothing at all — `AppSession`'s
`for try await hex in store.observeMetaValue(…)` compiles unchanged against the new
sequence type, which was the point of matching GRDB's semantics rather than inventing
easier ones. Recorded rather than left blank, because "nothing new" is only an acceptable
answer if somebody checked.

### GRDB's `ValueObservation.start` has two overloads and picks the wrong one
**Workstream:** wave-2 fixes · **Component:** GRDB, not `NextcloudUI` · **Severity:** friction
**Where:** `MailStore.swift`, `startTracking(_:in:scheduling:onError:onChange:)`

GRDB 7 declares `start(in:scheduling:onError:onChange:)` twice: a `nonisolated` one taking
`some ValueObservationScheduler`, and a `@MainActor` one taking
`some ValueObservationMainActorScheduler`. `.mainActor` satisfies both, and passing it from
a `nonisolated` context selects the `@MainActor` overload and fails with "call to main
actor-isolated instance method in a synchronous nonisolated context" — which reads as a
concurrency mistake rather than an overload-resolution one. The workaround is a helper
whose scheduler parameter is an opaque `some ValueObservationScheduler`, which the
main-actor overload cannot match. Noted here for whoever meets it next; it is a GRDB API
shape, not something this project can fix.

### Four store DAOs the sync engine had to work around
**Workstream:** WS-05 · **Component:** `NCMailStore` · **Severity:** friction
**Where:** `SyncScheduler+Mailbox.swift`, `SyncScheduler.swift`

`MailStore.read`/`write` are internal since
[ADR-0034](../decisions/0034-the-store-returns-its-own-sequence.md), which is right, and it
means a gap in the DAOs is now a gap the caller cannot route around. WS-05 met four and
worked around all four rather than reaching into `NCMailStore`. In rough order of how ugly
the workaround is:

1. **Nothing reads `pendingOperation`.** The conflict rule in `offline-queue.md` is "a read
   of `pendingOperation` inside the sync write transaction", and there is no DAO and no way
   to open the transaction. The engine reads the queue through `OperationDraining` either
   side of the write and repairs afterwards;
   [ADR-0037](../decisions/0037-the-queue-is-read-twice-around-the-sync-write.md) names the
   `upsert(envelopes:preservingPendingOperationsFor:)` that replaces it.
2. **No `setMailboxStats(unread:total:mailboxId:)`.** A sync response's `stats` is two
   integers; writing them means rebuilding a fifteen-column `MailboxWrite` from the
   `MailboxRecord` that was just read and calling `upsert(mailboxes:)`. It is safe — the
   write omits every mirror-bookkeeping column by design — and it is fifteen columns to
   move two.
3. **No `recordSyncSuccess(mailboxId:at:)`.** `setEnvelopeCursor(_:complete:mailboxId:lastSyncAt:)`
   is the only DAO that stamps `lastSyncAt` and clears `syncFailureCount` and
   `lastSyncError`, which is exactly what a successful sync means — so the engine calls it
   with the mailbox's existing cursor and completion flag passed straight back in. It
   works, and a reader is entitled to think sync is moving stage 1's cursor, which it must
   never do.
4. **`account.lastDeepReconcileAt` has no setter.** The column exists on `AccountRecord` and
   nothing writes it, so the weekly timer lives in `meta` under
   `sync.lastDeepReconcile.<accountId>` instead. Two homes for one fact is the kind of drift
   that is cheap to fix now and confusing in a year.

None of these blocked anything. They are listed together because they have one shape: the
store's write surface was designed around the backfill, and sync writes different columns.

### `MailClient` never reports how many bytes came back
**Workstream:** WS-05 · **Component:** `NCMailNet` · **Severity:** friction
**Where:** `SyncMetrics.envelopeBytesDown`

`sync-engine.md` asks the instrumentation for "bytes down". `MailClient.get` hands back a
decoded value, and `bytes(_:)` — the one verb that returns `Data` — is typed
`Endpoint<Data>` and so is unavailable for a JSON endpoint. So the counter sums the
`rawJSON` each envelope carries, which is the payload but not the response, and its
documentation has to say so. A `(value, byteCount)` overload, or a transport-level meter
`MailClient` could be handed, would make the number the one the document asks for. The live
measurement test works around it with its own `MailTransport` wrapper, which is fine for a
test and not something the app can do.

### `FakeTransport.fail` cannot say "never succeeds", and it cost a comment rather than a workaround
**Workstream:** WS-05 · **Component:** `NCMailTestSupport` · **Severity:** minor
**Where:** `SyncSchedulerTests.oneFailingMailboxDoesNotStopTheAccount`

WS-14 named this gap and its own doc comment tells callers to write `times: 10_000`, which
is what the test does. It reads as a magic number at the call site and needs a comment
explaining that it is not one. A `.always` case, or `times: Int? = nil` meaning forever,
would remove both. Recorded rather than fixed, because widening it is WS-14's call.

### Nothing new from `NextcloudUI`
**Workstream:** WS-05 · **Component:** — · **Severity:** —

`NCMailSync` has no view layer and WS-05 changed no file under `NextcloudMail/**`. Checked
rather than assumed.

## From WS-09 (message view, WebView, scheme handler)

### `NCNoteCard` combines its children, so a control inside it is unreachable to VoiceOver
**Workstream:** WS-09 · **Component:** `NCNoteCard` · **Severity:** blocker
**Where:** `NextcloudMail/Views/Message/BlockedContentBar.swift:22`

`NCNoteCard` ends with `.accessibilityElement(children: .combine)`, which is right for a
banner that only explains. The blocked-content bar is the shape the design asks for and it
is not that: it is a warning with two buttons, **Show images** and **Always show from this
sender**, and `.combine` makes both unreachable — the card reads as one label and the
buttons disappear from the rotor.

`NCChip` has the same constraint and solves it, by re-surfacing removal as an accessibility
action. `NCNoteCard` has no equivalent, so the bar puts its buttons *outside* the card in an
enclosing `VStack`. The result is correct and it is not the composition
[../architecture/rendering.md](../architecture/rendering.md) describes, which is one card
with its actions.

**What would have been better:** an `actions:` slot — `NCNoteCard(_:title:content:actions:)` —
that stays outside the combined element, or `children: .contain` when the content builder
contains anything focusable. A banner with a "Retry" or "Show anyway" button is the common
case, not an unusual one: it is also what the failed-body state and the phishing card in
this same screen want.

### `NCListItem` has no initialiser with `details:` and no `leading:`
**Workstream:** WS-09 · **Component:** `NCListItem` · **Severity:** friction
**Where:** `NextcloudMail/Views/Message/MessageThreadStrip.swift:48`

The thread strip wants sender, subject and date, and no avatar — the avatar is already in
the header six points above, and repeating it per sibling is noise. The five initialisers
cover every combination except that one, and the source comment says why: an unlabelled
trailing closure would match two overloads. So the strip draws an avatar it did not want.

**What would have been better:** the labelled form the comment already suggests,
`NCListItem(_:subtitle:details:)`. The ambiguity argument does not apply once the argument
is labelled, which is the case here.

### Nothing in the library knows about a `WKWebView`, and that is the right answer
**Workstream:** WS-09 · **Component:** — · **Severity:** —
**Where:** `NextcloudMail/WebView/**`

Recorded because the question will be asked. The whole of `NextcloudMail/WebView/**` is
app-specific: the scheme, the allowlist, the content rule list, the rewrite. None of it
belongs in `NextcloudUI`, and the library not reaching for it is correct rather than a gap.
The one thing that would help is a **message-header block** — sender bubble, recipients
collapsing past three, date — which `ui-components.md` already lists as a candidate. WS-09
built it in 90 lines out of `NCUserBubble` and `NCChip`, and the two decisions inside it
(collapse threshold, and what the "+3" control looks like) are the kind of thing a library
should settle once.

### `NCChip` inside a `Button` loses the chip's own pointer and hit target
**Workstream:** WS-09 · **Component:** `NCChip` · **Severity:** polish
**Where:** `NextcloudMail/Views/Message/MessageAttachmentsView.swift:41`

An attachment chip is a control: clicking it saves the file or previews it. `NCChip` takes
`onRemove:` and nothing else, so the chip goes inside a `Button` with `.buttonStyle(.plain)`
and the app supplies the label and the tooltip. It works. A chip that is *activatable* — the
`action:` that `NCUserBubble` already has — would make the attachment row three lines shorter
and would get the pointer style and hit target from the library rather than from the caller
remembering.

### The icon list from the design pass held, with one addition
**Workstream:** WS-09 · **Component:** `NCSymbolCatalog` · **Severity:** friction
**Where:** `NextcloudMail/MailSymbol.swift`

WS-09 needed `paperclip` (attachment chips), `sync` (the downloading and failed states) and
`inbox` (the nothing-selected state), all three already in WS-13's mapping and all three
still absent from the catalogue. Nothing new was needed, which is a good sign for that list.
The one it would have used if it existed is MDI `image-off-outline`, for the blocked-content
bar: the bar currently leans on `NCNoteCard(.warning)`'s own alert glyph, which says
"warning" rather than "pictures not shown".

### The leading slot holds one view, and a mail row needs four
**Workstream:** WS-08 · **Component:** `NCListItem` · **Severity:** friction
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift:32`

Confirmed, with the shape it forced. A message row carries three state glyphs — starred, has
an attachment, replied to — and each is optional. They have to sit in a column of fixed width
or rows with no glyphs put their avatars two points left of rows with one, and a list scanned
vertically stops lining up.

`NCListItem(_:subtitle:leading:details:trailing:)` gives the leading slot one view, so the
row builds `HStack { threeFixedSlots; NCAvatar(…) }` inside it and sizes the slots itself
from `theme.metrics.icon.small` and `theme.metrics.spacing.hairline`. Every absent glyph is a
`Color.clear` of that size. It works, it is 20 lines, and the 20 lines are the library's
alignment reimplemented by a caller who cannot see the library's spacing decisions.

**What would have been better:** an `accessories:` slot ahead of `leading:`, laid out by the
component at a width it decides from the metric scale, so every Nextcloud list that has
per-row state glyphs lines up the same way. Files wants exactly this too — shared, favourite,
locked.

### The short relative date is wrong for a mail list past about a week
**Workstream:** WS-08 · **Component:** `NCRelativeDateFormatter`, `NCListItemDetails` · **Severity:** friction
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift:40`

`ui-components.md` question 5, answered. `NCListItemDetails`'s default is
`NCRelativeDateFormatter(width: .short, ignoresSeconds: true)`, which is
`Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated)`. Measured output,
`en_US`:

| Age | Rendered |
| --- | --- |
| 3 minutes | `3 min. ago` |
| 2 hours | `2 hr. ago` |
| 1 day | `yesterday` |
| 5 days | `5 days ago` |
| 9 days | `last wk.` |
| 40 days | `last mo.` |
| 280 days | `9 mo. ago` |

The first four are right and are what the design pass expected. The rest are not what a mail
list shows. Every mail client switches to an absolute date past about a week — "12 Mar" — and
`presentation: .named` actively loses information doing the opposite: two messages three weeks
apart both read `last mo.`, so the column that is supposed to order the list stops ordering
it. `9 mo. ago` is also longer than `12 Mar` in a column that is 280 points wide in total.

The escape hatch does not escape. `NCListItemDetails(date:unreadCount:formatter:)` takes an
`NCRelativeDateFormatter`, and that type has `width`, `ignoresSeconds` and `locale` — there is
no way to express "relative under a week, absolute over it" through it, so a caller who wants
mail rules cannot use `NCListItemDetails` at all. WS-08 kept the library's default rather than
forking the row, because a row that draws its own date is a row that loses the component.

**What would have been better:** a `cutoff: Duration?` on `NCRelativeDateFormatter`, past
which it formats absolutely — `.dateTime.day().month(.abbreviated)` within the year,
`.year()` beyond it. Talk wants the same rule for a conversation list. Failing that, a
`formatter:` parameter on `NCListItemDetails` typed as `some FormatStyle<Date, String>` so a
caller can supply anything.

### `NCListItem` was never asked to be 50,000 rows, and that is the right answer
**Workstream:** WS-08 · **Component:** `NCListItem` · **Severity:** —
**Where:** `NextcloudMailTests/MessageList/MessageListPerformanceTests.swift:59`

`ui-components.md` question 1, answered as far as it can be answered here. The list is a
window over the database, so the largest array `ForEach` ever sees in this app is 60 rows on
selection and 2,580 after twenty-one scroll extensions, never 50,000. At a real 50,000-row
mailbox, selection to rows assigned is **1.8 ms flat and 2.3 ms threaded**, and extending the
window is **3.5 ms** — the database and the projection, measured, with no view in it.

So the question "does its `HStack` of optional slots cost enough to need a cheaper row" does
not arise at the counts this app builds. What was **not** measured is SwiftUI drawing those
rows and scrolling them at 60 fps: that needs a window, and there is no GUI in this
environment. WS-08's report says so plainly rather than implying a trace exists.

### `NCCounterBubble(count: 0)` drawing nothing is what made the thread badge one line
**Workstream:** WS-08 · **Component:** `NCCounterBubble` · **Severity:** —
**Where:** `NextcloudMail/Views/MessageList/MessageListRow.swift:44`

Recorded because the small correct decisions deserve a line too. The thread-count badge is
wanted on a thread of three and not on a thread of one, and `count: 0` rendering nothing at
all means that is `count: row.threadCount > 1 ? row.threadCount : 0` rather than an `if` and
a branch in the view builder. `NCListItemDetails` collapsing to zero width on a nil date and
a zero count has the same shape and the same payoff.

### Unanswered, because it needs a window
**Workstream:** WS-08 · **Component:** `NCListItem`, `NCAccentPolicy` · **Severity:** —
**Where:** —

`ui-components.md` question 2 — does `.fontWeight(.semibold)` still mark unread when the row
is selected and tinted by the brand colour — cannot be answered here. There is no GUI and
`screencapture` does not work, so nothing was rendered.

What can be said from the source is that the two do not compete for one property:
`NCListItem` sets `.font(.body)` with no explicit weight, with a comment saying that is so a
caller's `.fontWeight` on the whole row wins, and `List` draws selection as a background fill.
Whether semibold reads as heavier against a saturated brand fill is a contrast question and
needs eyes. It stays open, alongside question 3 (brand tint against the macOS selection
highlight in a three-column split view) and question 4 (MDI glyphs in a signed, sandboxed
release build).

### Nothing new from `NextcloudUI` — the queue draws nothing
**Workstream:** WS-06 · **Component:** — · **Severity:** —
**Where:** —

WS-06 is `NCMailSync/Operations/**` and its tests. It has no view, no symbol and no theme,
and it publishes a count for WS-13 to draw rather than drawing one. The library was not
exercised and there is nothing to report about it. The entries below are about
`NCMailStore` and `NCMailTestSupport`, which is where this workstream's friction actually
was.

### `NCMailStore` has the queue's table and no queries over it
**Workstream:** WS-06 · **Component:** `MailStore` · **Severity:** blocker
**Where:** `Packages/NCMailSync/Tests/NCMailSyncTests/OperationStoreSupport.swift:29`

The fourth time this file has recorded a missing store DAO, and the first time it stopped
the work rather than costing a workaround. `pendingOperation` and `PendingOperationRecord`
exist; nothing reads or writes them. `MailStore.write` is internal since ADR-0034, correctly,
so `applyLocally` and the queue insert cannot be put in one transaction from `NCMailSync` at
all — and that transaction is the whole of ADR-0005.

What we did instead: declared `OperationStoring` in `Operations/**` and conformed `MailStore`
to it in the **test** target, where `@testable` reaches `read`/`write`. Every test runs
against the real schema, and nothing outside `NCMailSync` can construct a `MutationQueue`.
ADR-0043 names the five methods and the file they belong in. The pattern to notice: WS-04
needed two DAOs, WS-05 needed four, WS-06 needs five and cannot ship without them. A store
that owns the GRDB stack has to own the queries too, or the boundary stops being a boundary
and starts being a queue of requests.

### `@testable import` reaches a module's types but not this free function
**Workstream:** WS-06 · **Component:** `MailStore`, `databaseQuestionMarks` · **Severity:** friction
**Where:** `Packages/NCMailSync/Tests/NCMailSyncTests/OperationStoreSupport.swift:154`

From `NCMailSyncTests`, `@testable import NCMailStore` resolves `MailStore.write`,
`PendingOperationRecord` and every record type, and does **not** resolve
`databaseQuestionMarks(count:)`, an internal file-scope function in the same module. The
compiler does not say "cannot find"; it says `error: failed to produce diagnostic for
expression; please submit a bug report`, which costs twenty minutes of bisecting a
thirty-line method to find out which symbol it meant. Worth an upstream report against the
toolchain. We copied the three lines rather than fight it.

### GRDB's names are not re-exported, so a cross-package test file must import it directly
**Workstream:** WS-06 · **Component:** `NCMailStore` · **Severity:** friction
**Where:** `Packages/NCMailSync/Tests/NCMailSyncTests/OperationStoreSupport.swift:5`

`Records/**` and `Projections/**` have `public import GRDB`, and ADR-0034 notes that "GRDB's
names are still visible to a module that imports `NCMailStore`". Partly. `Int.fetchOne(_:sql:)`
resolves through the re-export; `Database`, `StatementArguments` and `DatabaseValueConvertible`
named as types do not. So a test file that writes a store DAO needs `import GRDB` for a module
its package does not declare as a dependency. It compiles because SwiftPM has GRDB in the
search path, which is a coincidence rather than a contract. One more reason the DAO belongs in
`NCMailStore`, where the import is declared.

### `FakeTransport.fail` still cannot say "never succeeds"
**Workstream:** WS-06 · **Component:** `FakeTransport` · **Severity:** polish
**Where:** `Packages/NCMailSync/Tests/NCMailSyncTests/OperationDrainTests.swift:318`

Independently hit, and reported here a second time because WS-05's entry asked whether it was
a one-off. It is not: "the network is gone" is the central situation of this workstream, and
it is spelled `fail(route, times: 10_000, then: .status(200))`. The comment explaining that
10,000 means "forever" is now in two packages. `fail(route, alwaysWith: URLError(...))` would
remove both, and would also let a test choose the error — every failure this fake produces is
`URLError(.networkConnectionLost)`, so a test cannot tell a timeout from a DNS failure.
Not widened here: it is WS-14's API and this workstream is not the one to change it.

## From WS-07 (sidebar: accounts and mailbox tree)

### `NCNavigationItem` composes inside `DisclosureGroup` with no fighting at all
**Workstream:** WS-07 · **Component:** `NCNavigationItem` · **Severity:** —

The question the design pass and WS-08's `NCListItem` entry both raised for this row shape
does not arise here. A sidebar row needs exactly one icon and one count, which is precisely
`NCNavigationItem`'s two optional slots, so `MailboxTreeRowView` is `NCNavigationItem(...)`
used as a `DisclosureGroup`'s `label:` with nothing built around it — no accessory `HStack`,
no manual width. The component's own doc comment says nesting is `DisclosureGroup`'s job and
declines a `children:` parameter for exactly that reason; the decision holds up in a real
three-level tree (`NextcloudMail/Views/Sidebar/SidebarView.swift`).

### `NCNavigationItem` does not combine its children into one accessibility element
**Workstream:** WS-07 · **Component:** `NCNavigationItem` · **Severity:** friction
**Where:** `Sources/NextcloudUI/Components/NavigationItem/NCNavigationItem.swift:72`

The brief's acceptance criterion is "VoiceOver reads a mailbox row as name plus unread
count." `NCNavigationItem`'s body is a plain `HStack` — the title `Text`, `NCCounterBubble`
and the trailing-actions `Menu` are three separate accessibility elements, with no
`.accessibilityElement(children: .combine)` the way `NCListItem` already has
(`ListItem/NCListItem.swift:115`). Left alone, VoiceOver would swipe through "Inbox", then
separately "7 unread", instead of one stop.

Worked around at the call site: `MailboxTreeRowView.label` wraps the row in
`.accessibilityElement(children: .combine)` itself, which is safe here only because a plain
mailbox row carries no other focusable content — its context menu is a native
`.contextMenu`, not a persistent button, so nothing disappears from the rotor the way
`NCNoteCard`'s buttons did for WS-09. The account header does **not** get the same
treatment, because its trailing actions `Menu` does need its own stop; `NCNavigationCaption`
already leaves its own children uncombined, which is the right default for a component with a
control on it.

**What would have been better:** `NCNavigationItem` combining its own children the same way
`NCListItem` does, since a row with no `actions:` closure (`NCNavigationItem<EmptyView>`) has
nothing that a combine could break, and the common sidebar case — icon, title, count, no
actions menu — is exactly that shape.

### The icon list holds; nothing new past what WS-13 already built
**Workstream:** WS-07 · **Component:** `NCSymbolCatalog` · **Severity:** —

Every role this workstream draws — inbox, drafts, sent, archive, junk, trash, plus the plain
folder for an ordinary or synthetic container — was already a `MailSymbol` case. No new icon
was needed.

### Question 3 (brand tint vs. macOS selection in a three-column split view) is still open
**Workstream:** WS-07 · **Component:** `NCAccentPolicy` · **Severity:** —

Still unanswerable here: no GUI, no `screencapture`, and `RootSplitView` still shows a
placeholder in the sidebar's slot rather than this workstream's view (see the report). The
sidebar is the column with the densest selection surface of the three — a `List` several
levels deep, nested in `DisclosureGroup`s — so it is the strongest test of this question once
someone can actually look.

## From the store-DAO pass (ADR-0045)

### `NCAvatar` and `NCUserBubble` take exactly the loader a local-first client wants
**Workstream:** store-DAO pass · **Component:** `NCAvatar`, `NCUserBubble` · **Severity:** —

`load: (@Sendable () async throws -> Image)?` is the right shape and worth recording as such,
because the obvious alternative — a URL, the way `AsyncImage` takes one — would have been
unusable here. This app must never let a view reach the network, so the picture has to come
out of the mirror; a closure lets the caller decide where bytes come from, and `nil` is a
first-class "do not try". Wiring both call sites was a one-line change each once
`MailStore.avatar(for:)` existed.

The fallback contract helps too: the component draws coloured initials when the loader
throws, so "no row yet" and "the server answered 404" need no branch at the call site even
though they are different facts the fetcher will have to tell apart.

### `NCAvatar`'s cache key includes the diameter, which is right and worth saying out loud
**Workstream:** store-DAO pass · **Component:** `NCAvatar` · **Severity:** —

`NCAvatar.cacheIdentity` folds the size into the key
(`Components/Avatar/NCAvatar.swift:135`). A mail client draws the same sender at two sizes on
one screen — `.medium` in the list row and `.medium` in the message header today, and the
header will want to grow — and a key that ignored the size would hand one of them the other's
bitmap. Nothing to change; it is the sort of decision that is invisible until it is wrong.

### Nothing new otherwise
This pass was store queries and the two call sites above. No component was bent, and no icon
was missing.
