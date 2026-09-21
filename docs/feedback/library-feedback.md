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
