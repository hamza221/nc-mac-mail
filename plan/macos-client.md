# Native macOS client for Nextcloud Mail

## Context

`hamza221/nextcloud-swiftui` (the `NextcloudUI` package) has all six waves built and its
README names the next step: "Build a real Mail client against it, and freeze the API on
what that finds." `docs/ROADMAP.md` says the same thing more bluntly. The Mail screen in
`NextcloudShowcase` is a demo inside the package, so it proves less than a client built
from outside.

`./plan/API.md` and `./plan/features.md` in this directory already map every Nextcloud
Mail endpoint and every feature of the Vue client. This plan turns the first slice of
that into a macOS app: log in, read mail, triage it. The point is both a usable client
and a list of places where the component API gets in the way.

Scope for v1, as chosen: read and triage. No composer.

## Decisions taken

- Xcode project checked into git. Xcode runs `actool`, so the 91 Material Design Icons
  render as real glyphs. SwiftPM alone copies the asset catalogue uncompiled and
  `NCIcon` falls back to SF Symbols. The app bundle also gives an Info.plist, the
  Keychain, `WKWebView` and a route to notarization.
- Depend on `https://github.com/hamza221/nextcloud-swiftui`, branch `main`.
- App password over Login Flow v2. No stored user password, and revocable server side.
- No local database. The server already caches IMAP in its own tables and every list
  endpoint is paginated. State lives in one `@Observable` store for the session.

## Authentication, and why it works

Verified in `nextcloud/server`, `lib/private/AppFramework/Http/Request.php`:
`passesCSRFCheck()` returns `true` as soon as the `OCS-APIRequest` header is present,
and `cookieCheckRequired()` returns `false` when the request carries no session cookie.
So an app password over HTTP Basic, plus that one header, is accepted by the Mail app's
non-OCS routes under `/index.php/apps/mail/api/`, which otherwise demand a `requesttoken`.

Flow:

1. `POST {server}/index.php/login/v2`, no auth. The `User-Agent` becomes the name of the
   app password in the user's security settings, so set it to `Nextcloud Mail (macOS)`.
   Response: `{login, poll: {token, endpoint}}`.
2. Open `login` with `NSWorkspace.shared.open`.
3. `POST poll.endpoint` with the form body `token=<token>` every 2 seconds. It answers
   404 until the user finishes in the browser, then 200 with
   `{server, loginName, appPassword}`. Give up after 5 minutes.
4. Store `appPassword` in the Keychain as a `kSecClassInternetPassword` item keyed by
   server host and `loginName`.
5. Every later request carries `Authorization: Basic base64(loginName:appPassword)`,
   `OCS-APIRequest: true` and `Accept: application/json`.

Step 0 of the work is a curl against a real instance confirming this, before any Swift
is written:

```sh
curl -u 'user:app-password' -H 'OCS-APIRequest: true' -H 'Accept: application/json' \
  'https://cloud.example/index.php/apps/mail/api/accounts'
```

A 412 or a CSRF error there means the fallback is a session cookie plus a `requesttoken`
scraped from `/index.php/apps/mail/`, and the plan changes shape. A JSON array means
everything below holds.

## Files

```
NextcloudMail.xcodeproj
NextcloudMail/
  NextcloudMailApp.swift       @main, NavigationSplitView scene, .ncTheme, Settings, Commands
  Server/
    LoginFlow.swift            Login Flow v2 state machine
    Keychain.swift             two functions over SecItem
    MailClient.swift           URLSession, auth headers, typed get/post/put/delete
    Models.swift               Account, Mailbox, Envelope, MessageBody, Address, Flags
  Mail/
    MailStore.swift            @Observable: accounts, mailboxes, messages, actions
    MailboxTree.swift          flat mailbox list to tree, pure, testable
  Views/
    LoginView.swift
    SidebarView.swift
    MessageListView.swift
    MessageDetailView.swift
    MessageBodyWebView.swift   NSViewRepresentable over WKWebView
    AvatarLoader.swift         @Sendable () async throws -> Image for NCAvatar
NextcloudMailTests/
  MailboxTreeTests.swift
  DecodingTests.swift          recorded JSON fixtures from the real server
```

## Phases

Each phase ends with something that runs.

### 1. Project and theme

Create the app target (macOS 26, Swift 6.2, strict concurrency, `defaultIsolation`
MainActor to match the package). Add the package dependency and the `NextcloudUI`
product. Empty `NavigationSplitView` with `.ncTheme(theme)` at the scene root.

Read the instance brand on launch: `GET {server}/ocs/v2.php/cloud/capabilities` gives
`data.capabilities.theming.color`, feed it to `NCBrand(primaryHex:)` and assign
`NCTheme(brand:)`. One assignment recolours the running app, per the package README.

Entitlements: App Sandbox with outgoing network connections. If the local ad-hoc
signature blocks `SecItem`, develop with the sandbox off and turn it back on before any
release build.

### 2. Login and the HTTP client

`LoginFlow.swift` implements the four steps above. `Keychain.swift` is two functions,
`save(password:server:account:)` and `password(server:account:)`, over `SecItem`.

`MailClient` is a `struct` holding the server URL and credentials with one generic
request method:

```swift
func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T
```

plus `post`, `put`, `delete`. Paths are relative to `{server}/index.php/apps/mail/api/`.
Map 401 to a re-login, and decode the app's `{data: …, status: "error"}` failure envelope
where it appears.

`LoginView` is a server URL field and a button. On success it stores the password and
hands the client to the store.

Check: launch, log in, print the account list.

### 3. Sidebar

`GET /api/accounts` returns the accounts. Fields that matter here: `id`, `name`,
`emailAddress`, `order`, and the special mailbox ids `draftsMailboxId`, `sentMailboxId`,
`trashMailboxId`, `archiveMailboxId`, `junkMailboxId`, `snoozeMailboxId`.

`GET /api/mailboxes?accountId=` returns `{id, email, mailboxes: [...], delimiter}`. Each
mailbox carries `databaseId` (the id every other endpoint wants), `name` (the full IMAP
path), `displayName`, `delimiter`, `specialUse`, `specialRole`, `unread` and
`syncInBackground`. Note that `id` is base64 of the name, not the numeric id; use
`databaseId` everywhere.

`MailboxTree.swift` splits `name` on `delimiter` into a tree and orders the special roles
first: inbox, drafts, sent, archive, junk, trash, then the rest alphabetically. Pure
function, covered by `MailboxTreeTests`.

The view is a `List` with `NCNavigationCaption` per account and `NCNavigationItem(name,
icon: .folderOutline, count: unread)` per mailbox, with `DisclosureGroup` for children.
This is the showcase's `MailScreenDemo` (`Sources/NextcloudShowcase/Showcase.swift:626`)
rebuilt as a real `NavigationSplitView` column, which is what that demo's own
`ponytail:` comment asks for.

### 4. Message list

`GET /api/messages?mailboxId=&limit=50&view=threaded&cursor=` returns envelopes. Each has
`databaseId`, `subject`, `dateInt`, `previewText`, `from`/`to`/`cc` as `[{label, email}]`,
`flags` (`seen`, `flagged`, `answered`, `hasAttachments`, `important`, `$junk`, …),
`tags`, `threadRootId` and `mentionsMe`. `cursor` is the `dateInt` of the last envelope
loaded, so paginate by passing it and appending.

The row is `NCListItem(sender, subtitle: subject)` with `NCAvatar` leading and
`NCListItemDetails(date:unreadCount:)` as details, `.fontWeight(.semibold)` when unread.
Infinite scroll through `.onAppear` on the last row.

Refresh: `POST /api/mailboxes/{databaseId}/sync` with the known ids returns new, changed
and vanished messages. A 428 means the mailbox is not cached yet, so retry once with
`init: true`.

Avatars: `GET /api/avatars/image/{urlencoded email}` through the authenticated client,
wrapped as the `@Sendable () async throws -> Image` loader `NCAvatar` takes. `NCAvatar`
draws coloured initials when the loader throws, so a 404 needs no special case.

### 5. Message detail

`GET /api/messages/{id}/body` returns the parsed message plus `attachments`,
`inlineAttachments`, `isSenderTrusted`, `smime` and `dkimValid`.
`GET /api/messages/{id}/html` returns the sanitised HTML document for the body.

Header: subject as `.title2`, sender as `NCUserBubble`, recipients as `NCChip`, date,
and an attachment row.

Body: `MessageBodyWebView` wraps `WKWebView` and calls `loadHTMLString(html, baseURL:
nil)`. Three rules, none of them optional:

- `defaultWebpagePreferences.allowsContentJavaScript = false`.
- A `WKContentRuleList` blocking `image`, `style-sheet` and `font` loads, so remote
  content cannot leak the reader's IP. A "show images" button removes the rule list and
  reloads. This mirrors the web client's blocked-content bar.
- A navigation delegate that cancels every navigation after the first and opens the URL
  in the default browser instead.

Thread: `GET /api/messages/{id}/thread` lists the sibling messages, rendered collapsed
with the selected one expanded.

Attachments: `GET /api/messages/{id}/attachment/{attachmentId}` to a save panel,
`GET /api/messages/{id}/attachments` for the zip.

### 6. Triage

Optimistic local mutation, reverted when the request fails.

| Action | Call |
| --- | --- |
| Read, unread, star, important | `PUT /api/messages/{id}/flags` with `{"flags": {"seen": true}}` |
| Archive | `POST /api/messages/{id}/move` with `destFolderId: account.archiveMailboxId` |
| Delete | `DELETE /api/messages/{id}` (trash, or erase when already in trash) |
| Junk | flags `$junk` then move to `junkMailboxId` |
| Move | `POST /api/messages/{id}/move` with a mailbox picked from a `Menu` |
| Whole thread | the same verbs under `/api/thread/{id}` |

Buttons go in the detail toolbar with `NCButtonStyle` and in a `.contextMenu` on the row.
Keyboard shortcuts through `.keyboardShortcut`, matching the web client where it costs
nothing: `A` archive, `S` star, `U` unread, `Delete` delete, `R` refresh.

## Verification

Needs a Nextcloud instance with the Mail app installed and at least one mail account
configured on it.

1. The curl in step 0 returns the account list as JSON.
2. `xcodebuild -scheme NextcloudMail build` is clean. The package builds warnings-as-
   errors, so keep the app target on the same setting.
3. `xcodebuild -scheme NextcloudMail test` runs `MailboxTreeTests` and `DecodingTests`.
   The decoding fixtures are real responses saved with curl, so a server-side shape
   change fails the build instead of the app.
4. Run it: log in, pick a mailbox, scroll past the first page, open a message with remote
   images and confirm nothing loads until "show images", archive it with `A`, confirm in
   the web client that the message moved.
5. Change the instance's theme colour in the admin settings, relaunch, confirm the app
   recolours.
6. Open the Xcode scheme, not `swift run`, and confirm the sidebar icons are Material
   Design glyphs rather than SF Symbols.

## Notes for the library

Keep a running list in `plan/api-feedback.md` of every place `NextcloudUI` needed a
workaround. That list is the deliverable the package README is waiting for.

## Deliberately left out

Compose, drafts and the outbox. Search and the filter string. Tags, snooze, quick
actions, priority inbox, S/MIME, OpenPGP, Sieve, out of office, the AI features, itinerary
cards, and account setup inside the app (accounts are configured in the web client for
now). Offline storage. Unified inbox. Drag and drop onto folders.

Add compose once the read path is proven, since it is the half the library has no
components for: `NCRichContenteditable` and `NCRichText` are both deferred to v1.1, so a
composer is either plain text or an `NSTextView` bridge this client would have to write.
