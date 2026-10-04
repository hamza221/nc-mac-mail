<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Nextcloud Mail server findings

*What building a native, mirroring client found in `nextcloud/mail`. Every entry cites a
file, because an uncited finding cannot be acted on.*

Version examined: **5.12.0-rc.1** (`appinfo/info.xml`), `main`. Findings were produced
between 2026-09-21 and 2026-09-23 by a macOS client that downloads every subscribed mailbox
and keeps a complete local copy. Curated on 2026-09-23.

Nothing here is a complaint about a bad API. All of it is an API designed for one client, a
Vue app that shows a page of mail at a time, meeting a second client with different needs.
That is what the exercise was for.

Ordered by what a maintainer should act on first: the four ways a mirroring client silently
loses mail, then one privacy leak, then what a full download costs, then the shapes that
cost a typed client an afternoon each. Numbering changed at curation, and nothing outside
this file cites it by number. Issue text ready to post is in
[upstream-issues.md](upstream-issues.md).

---

## Correctness: four ways a client that enumerates loses messages

### 1. `newMessages` contains thread heads only

**Where:** `lib/Db/MessageMapper.php::findNewIds`, the self-join on `thread_root_id` with
`m2.id IS NULL`
**Kind:** probably unintended for this endpoint · **Impact:** high

Threaded-view filtering is applied to a **sync** response. Two new messages arrive in one
thread and a client hears about one. For a list that renders thread heads this is invisible.
For a mirror it is silent data loss, and it forces every mirroring client to page the whole
message list after each sync as a safety net.

**Suggestion:** return every new message from `sync` regardless of threading, and let the
client group them. Threading is a display concern. Sync is not display.

### 2. `cursor` is strictly exclusive, so a duplicate `dateInt` at a page boundary is unreachable

**Where:** `lib/Controller/MessagesController.php::index`,
`lib/Db/MessageMapper.php::findIdsByQuery`
**Kind:** correctness · **Impact:** high

`cursor` is a `dateInt` and the comparison is `<`. Reproduced against 5.12.0-rc.1:
`GET /messages?mailboxId=5&view=singleton&limit=3` ends at `dateInt` 1789590490, and
`&cursor=1789590490` returns only messages older than it, never it.

Two messages can share a `dateInt`. The test account's inbox has ids 44 and 45 both at
1778515439, and `dateInt` is second resolution, so on a busy mailbox this is common rather
than exotic. When a page's `limit` falls between two such messages, the client sends the
first one's `dateInt` as the cursor and the second becomes unreachable by pagination. There
is no error, no gap in any count the client can see, and no second chance, because every
subsequent page is strictly older.

A client can work around it by sending `oldest dateInt + 1` and tolerating one duplicated
row per page, which is what this client does
([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)). It should not have to, and a
client that reads the parameter's name and does the obvious thing loses mail silently. The
web client does not hit it because it never enumerates a whole mailbox.

**Suggestion:** make the cursor a `(dateInt, id)` pair, or document the `+ 1`.

### 3. Sort order is a stored user preference that silently inverts pagination

**Where:** `lib/Controller/MessagesController.php::index` reads the `sort-order` preference;
`lib/Db/MessageMapper.php`
**Kind:** correctness and design · **Impact:** high for any client that enumerates
**Found twice:** once by reading the controller, once by measuring a live instance.

`GET /api/messages` takes no sort-order parameter. It reads the user's stored `sort-order`
preference, and that one value changes two things at once: which end of the mailbox page one
comes from, and which way `cursor` compares.

Measured on a live 5.12.0-rc.1 instance, setting the preference and putting it back:

| | `newest` or unset | `oldest` |
| --- | --- | --- |
| `limit=5` | ids 167, 166, 165, 164, 154, newest first | ids 23, 24, 25, 26, 27, oldest first |
| `cursor=<dateInt>` | returns messages **older** than it | returns messages **newer** than it |
| `&sortOrder=newest` in the query string | ignored | ignored |

Two consequences for a client that mirrors a whole mailbox. Pagination arithmetic has to
flip with a value the client did not send and cannot override per request, so the workaround
for finding 2 becomes `newest dateInt - 1` instead of `oldest dateInt + 1`. And a "page from
the newest until you recognise everything" scan, which is how this client catches the thread
siblings finding 1 omits, cannot be expressed at all: under `oldest` the newest messages are
at the far end of the walk.

The failure is silent in the worst way. Nothing errors. The enumeration advances by one row
per page instead of by a hundred, so a mailbox that took 500 requests takes 50,000 and looks
like a slow server. A second client changing the preference changes the first client's
pagination mid-run.

**Suggestion:** accept `sortOrder` as a query parameter on `GET /api/messages`, defaulting
to the preference, as `POST /sync` already does in its body. It is one line in the
controller and it lets a client ask for what it needs without touching a user-visible
setting.

### 4. `POST /sync` returns every id you claim to know

**Where:** `lib/Service/Sync/SyncService.php::getDatabaseSyncChanges`, which carries its own
`// TODO: $changed = $this->messageMapper->findChanged(...)`
**Kind:** known gap · **Impact:** high

`changedMessages` is every id in the request that still exists, in full. There is no change
detection. A client that knows a lot must therefore send a small window and accept blind
spots outside it ([ADR-0015](../decisions/0015-bounded-sync-window.md)), or send everything
it has and receive its own mailbox back.

**Suggestion:** implement the `TODO`, or add a `since` token so a client can ask what
changed since X instead of describing everything it holds.

---

## Privacy

### 5. `TransformImageSrc` rewrites `<img>` and not CSS, so `@import` survives sanitisation

**Where:** `lib/Service/HtmlPurify/TransformImageSrc.php`
**Kind:** privacy leak · **Impact:** high for a client without a content security policy
**Found by:** WS-09, rendering a recorded body

The transform replaces every remote `<img src>` with a blocked placeholder and stashes the
original in `data-original-src`. HTMLPurifier keeps `<style>` blocks, and nothing in the
chain touches the URLs inside them.

Reproduction, from a real marketing email recorded as
`message-html-plain.html` in this repository's fixtures. Nine images blocked, a 1x1 tracking
pixel neutralised, and the `<style>` block opens with:

```css
@import url(https://static-forms.klaviyo.com/fonts/api/v1/U45QAK/custom_fonts.css);
```

A browser rendering that fragment fetches it. It is a fourth host, it is not blocked, and it
is a request that tells the sender's font CDN when the message was opened and from where, in
a message whose images are all blocked. The web client renders the fragment in an iframe
with a CSP, which may or may not stop it depending on the policy. A native client with no
CSP has nothing in the way, and the whole point of the server-side blocking is that a client
should not need one.

**What this client does:** deletes every `@import` and rewrites every `url(...)` through the
same allowlist as `<img>`
([ADR-0039](../decisions/0039-a-rendered-message-holds-only-urls-we-would-fetch.md)).
Messages lose web fonts and CSS background images that the server would have proxied
happily.

**Suggestion:** extend the transformation to CSS `url()` and `@import`, either by dropping
them or by routing them through `/proxy` the way images go. The proxy exists and already
signs its URLs. This is the same treatment for the other half of the document.

---

## Cost

### 6. No bulk body endpoint, and the wall-clock cost of one body varies eightfold

**Where:** `lib/Controller/MessagesController.php::getBody`
**Kind:** design for browsers · **Impact:** high for any mirroring client

`GET /api/messages/{id}/body` opens an IMAP connection, fetches one message, parses and
sanitises it. Mirroring a 50,000-message account means 50,000 of those. This client handles
it with bounded concurrency, newest-first ordering, backoff and pausing
([ADR-0003](../decisions/0003-local-first-full-mirror.md)), and it is still the single
largest cost of being a native client.

**The measurement, which is the argument.** Mirroring a 155-message account three times with
identical code and two body fetches in flight took **183 s, 213 s and 1,498 s**. The request
count is the same every time. What moves is how long `/body` takes to open an IMAP
connection, fetch, parse and sanitise, and it varies eightfold between otherwise identical
runs. A client cannot make this smaller by being politer, because it is already inside its
concurrency budget. At 1.4 s per message, a 50,000-message account is 19 hours of a server
doing one message at a time.

**Suggestion:** `POST /api/messages/bodies` taking up to about 50 ids and returning them in
one response, reusing one IMAP connection. It cuts round trips by a factor of fifty and lets
the server choose the batch size, which is better for everyone than a client guessing.

---

## Shapes that cost a typed client an afternoon

These are cheap to fix and each one is discovered by a bug rather than by reading the
OpenAPI spec.

### 7. PHP's types reach the wire in three places, and each breaks a strict decoder

**Where:** `lib/Db/Message.php::jsonSerialize` (`tags`, `mentionsMe`);
`lib/Db/Mailbox.php::jsonSerialize` (`specialRole`, which is `$specialUse[0] ?? 0`)
**Kind:** typing · **Impact:** low each, and every strictly typed client hits all three
**Found by:** WS-02, writing the first decoding tests against recorded payloads

Counted in this repository's recorded fixtures, which are byte-for-byte what the server
sent:

- **`tags` is a dictionary keyed by IMAP label, except when it is empty.** PHP serialises an
  empty associative array as `[]`, so an envelope with no tags sends `"tags": []` and one
  with tags sends an object. **7 of the 95 envelopes** in `messages-inbox-page1.json` take
  the array form. A decoder that accepts only the object form fails on an ordinary message.
- **`mentionsMe` is the integer `0` or `1`, not a boolean.** It is written by a `COUNT(*)`
  and never cast. All 95 envelopes carry an integer.
- **`specialRole` is the integer `0` when a mailbox has no special use**, and a string
  otherwise. **2 of the 7 mailboxes** in `mailboxes-account.json` send the integer.

Each is a decoding failure for anyone who writes the obvious `Codable`, `dataclass` or
`interface` and does not first read someone else's client. This client documents and works
around all three in
[api-payloads.md](../reference/api-payloads.md).

**Suggestion:** cast at the point of serialisation. `(object)` for the empty tag map,
`(bool)` for `mentionsMe`, and `null` rather than `0` for an absent `specialRole`.

### 8. A stale id answers 403 with a body of `[]`, not the documented error envelope

**Where:** `lib/Controller/MessagesController.php`, `lib/Controller/MailboxesController.php`,
via `DelegationService`
**Kind:** undocumented behaviour · **Impact:** medium for a mirror, which hands the server
stale ids constantly
**Found by:** WS-02

Against 5.12.0-rc.1, every one of these answers **HTTP 403** with a body of exactly `[]`,
recorded as `error-message-forbidden.json` and `error-mailbox-forbidden.json`:

```
GET /api/mailboxes/99999999/stats   -> 403  []
GET /api/messages/99999999          -> 403  []
GET /api/messages/99999999/body     -> 403  []
```

`DelegationService` resolves the effective user for every id before the controller runs, and
an id that does not exist cannot be resolved to one the caller may see, so "gone" and "never
yours" are the same answer. That is defensible. What costs a client a day is that it is not
the `JsonResponse::fail` envelope the rest of the API uses, and that **403 does not mean the
account lost its delegation**. It is the ordinary answer to a stale id, which a mirror
produces every time someone deletes a message in the web client. A client that treats 403 as
an auth failure signs the user out for no reason.

`POST /api/mailboxes/{id}/sync` on a non-existent mailbox answers **405** with an HTML body,
because the route only matches an existing id, which is a third shape for the same class of
event.

**Suggestion:** document that 403 with an empty body means "this id is gone, do not
reauthenticate". Returning the standard error envelope would be better, and either is better
than the current silence.

### 9. `flags` is an object on the envelope and an array on the body

**Where:** `lib/Db/Message.php::jsonSerialize` versus
`lib/Model/IMAPMessage.php::jsonSerialize`
**Kind:** inconsistency · **Impact:** low, one extra model in every typed client

**Suggestion:** one shape. The object form is more useful.

### 10. `mailbox.id` is base64 of the name

**Where:** `lib/Db/Mailbox.php::jsonSerialize`, `'id' => base64_encode($this->getName())`
**Kind:** naming · **Impact:** medium for a newcomer

A field called `id` that is not the identifier, next to `databaseId` which is, next to an
always-empty `mailboxes` array that looks like it should hold the hierarchy. Three traps in
one payload, and each one is found by a bug.

**Suggestion:** document it in the OpenAPI spec at minimum. Renaming is a breaking change;
the documentation is free.

### 11. `displayName` is the full IMAP path

**Where:** `lib/Db/Mailbox.php::jsonSerialize`, `'displayName' => $this->getName()`
**Kind:** naming · **Impact:** low

Every client splits it on the delimiter to get something displayable, so every client
reimplements the same function.

**Suggestion:** make `displayName` the leaf, or add `leafName`.

### 12. `selectable` is computed and then not serialised

**Where:** `lib/IMAP/MailboxSync.php:220` sets it; `lib/Db/Mailbox.php::jsonSerialize` omits
it
**Kind:** omission · **Impact:** low

Clients re-derive it from `attributes` containing `\noselect`. Subscription is the same
story: `\subscribed` in `attributes`, with the Vue client lowercasing before it compares
(`src/components/NavigationMailbox.vue:289`), so every client has to know to do the same.

**Suggestion:** serialise `selectable` and `subscribed` as booleans. The information is
already computed.

### 13. Two names for the destination mailbox

**Where:** `lib/Controller/MessagesController.php:379` (`destFolderId`) versus
`lib/Controller/ThreadController.php:55` (`destMailboxId`)
**Kind:** inconsistency · **Impact:** low, and it costs every new client an afternoon

**Suggestion:** accept both on both, deprecate one.

### 15. The image proxy labels every image `application/octet-stream`

**Where:** `lib/Controller/ProxyController.php`, both `return new ProxyDownloadResponse(…,
'application/octet-stream')` sites
**Found by:** first manual QA pass of the macOS client, when no remote image ever loaded
**Kind:** inconsistency · **Impact:** medium for any non-browser client

A browser sniffs `<img>` responses and never notices. A client serving the bytes to a
sandboxed WebView through a custom scheme has to name a type. Trusting the header would mean
rendering nothing, and believing it means guessing. The macOS client now reads the magic
number itself. The upstream response already has the bytes, and `getHeader('Content-Type')`
from the fetched response or `finfo` would give the real type.

**Suggestion:** pass the upstream image's content type through, restricted to `image/*`
raster types, and send `X-Content-Type-Options: nosniff` with it.

### 16. Contact photos never reach the avatar routes

**Where:** `lib/Service/ContactsIntegration.php::getPhotoUri`
**Found by:** manual QA of the macOS client, when Nextcloud Contacts photos showed initials
**Kind:** omission (the code says `// TODO: fix`) · **Impact:** high; most contact photos

Nextcloud Contacts stores a photo inside the vCard, as a data URI or `ENCODING=b`.
`getPhotoUri` keeps a `PHOTO` only if it starts with `VALUE=uri:`, then cuts from the first
`http`, so every embedded photo comes back null. Both `/api/avatars/url` and
`/api/avatars/image` then answer "no avatar" for exactly the people a user knows best. A
client can only get them through CardDAV directly: an `addressbook-query` on `EMAIL`,
then `{card}.vcf?photo&size=…` from the DAV `ImageExportPlugin`.

**Suggestion:** when `PHOTO` is embedded, return an internal avatar pointing at the card's
`?photo` URL. The DAV app already decodes and caches the image there (`PhotoCache`). Serve it
through `/api/avatars/image` too, so a client needs one route for every avatar.

---

## Client configuration a non-browser client cannot read (WS-16, v2)

Found while writing [../reference/server-flags.md](../reference/server-flags.md) against
Mail 5.12.0-rc.1 on Nextcloud 36, 2026-10-03.

### 17. The appendix flags exist only as initial state in the HTML page

**Where:** `lib/Controller/PageController.php::index` (`provideInitialState` for
`allow-new-accounts`, `disable-scheduled-send`, `disable-snooze`,
`importance_classification_default`, `google-oauth-url`, `microsoft-oauth-url`, and the
`preferences` blob carrying `attachment-size-limit`)
**Kind:** design for one client · **Impact:** medium

Capabilities carry no `mail` section and `GET /api/preferences/{key}` reads user
preferences only, so these seven values are unreachable without loading and parsing the
web page. The provisioning API exposes three of the underlying app-config keys, to admins
only. A native client therefore treats them as "on" (ADR-0078) and learns otherwise from an
error — when there is one.

**Suggestion:** a `mail` capability (or `GET /ocs/v2.php/apps/mail/config`) with the same
values `PageController` already computes.

### 18. "New accounts disabled" answers a generic error

**Where:** `lib/Controller/AccountsController.php::create`, the
`ALLOW_NEW_MAIL_ACCOUNTS` check → `MailJsonResponse::error('Could not create account')`
**Kind:** error message · **Impact:** low

The same text as an unexpected `ServiceException` a few lines later, so a client surfacing
the server's message cannot tell the user that their admin turned this off.

**Suggestion:** a 403 with "Creating mail accounts is disabled by your administrator".

### 19. Omitting `classificationEnabled` on create ignores the admin default

**Where:** `lib/Controller/AccountsController.php::create` passes `null` to
`SetupService::createNewAccount`; `lib/Db/MailAccount.php` keeps its property default
`classificationEnabled = true`; only `Command/CreateImapAccount.php` and
`CreateJmapAccount.php` call `isClassificationEnabledByDefault()`
**Kind:** probably unintended · **Impact:** low

The web form sends the admin's default explicitly, so it never notices. Any other client
that omits the parameter gets `true`.

**Suggestion:** apply `ClassificationSettingsService::isClassificationEnabledByDefault()`
when the parameter is null, as the CLI commands do.

### 20. `attachment-size-limit` and the cron-mode flags are not enforced

**Where:** `attachment-size-limit` is read only by `src/components/Composer.vue`;
`disable-scheduled-send`/`disable-snooze` only by `PageController` — `AttachmentsController`,
`OutboxController` and the snooze routes never check them
**Kind:** client-side policy · **Impact:** low

A client that cannot read the flags (finding 17) cannot honour them either, and the server
accepts the oversized upload or the scheduled send on an ajax-cron instance silently.

### 21. 202 means two opposite things

**Where:** `lib/Controller/MailboxesController.php` (sync: `JsonResponse::fail([], 202)`,
"not done") versus `DraftsController::update`/`destroy`/`move` and
`OutboxController::update`/`send`/`destroy` (`JsonResponse::success(…, 202)`, "done")
**Kind:** shape · **Impact:** high for a client that maps statuses once

A typed client that learned 202 from sync throws on every successful draft save and every
send — and a queue that retries a "failed" send sends twice. This client reads the envelope
to tell them apart (ADR-0077).

**Suggestion:** 200 for the drafts and outbox successes; 202 stays sync's.

### 22. Sieve-off filter routes answer an HTML 500

**Where:** `GET`/`PUT /api/filter/{accountId}` with ManageSieve disabled
**Kind:** error shape · **Impact:** low

The sibling routes (`/api/sieve/active/{id}`, `/api/out-of-office/{id}`) answer a clean 400
`{"status":"fail","data":{"message":"ManageSieve is disabled"}}`; the filter routes answer
the full Nextcloud HTML error page with status 500, so a client has no message to show.

**Suggestion:** catch the same `ClientException` and answer the 400 the siblings do.

### 23. Three Sieve routes, three wrapping conventions

**Where:** `GET /api/sieve/active/{id}`, `GET /api/filter/{id}`, `GET /api/out-of-office/{id}`
with ManageSieve on (recorded by WS-21's scratch lifecycle, ADR-0080)
**Kind:** shape · **Impact:** medium — each silently decodes wrong under the obvious model
**Found by:** WS-21, the first recording with Sieve enabled

The active script answers bare `{"scriptName": …, "script": …}`; the filters answer a bare
array; the out-of-office route answers the `{"status","data"}` envelope around
`{"state": …|null, "script", "untouchedScript"}`, where `state` is the out-of-office
settings and is null until they were ever saved. With Sieve off all three answer the
envelope (finding 22 aside). A client that modelled them from the Sieve-off recordings —
as this one had — reads every script as nil and fails every filter list.

**Suggestion:** one convention for the three; the envelope is what the rest of the
settings surface uses.

### 24. A trusted address disappears from the listing while its domain is trusted

**Where:** `GET /api/trustedsenders`
**Kind:** behaviour · **Impact:** low, confusing in a settings list
**Found by:** WS-21, recording a list with one domain and one address

Trust `example.org` as a domain, then `someone@example.org` as an individual: both `PUT`s
answer 201, and the listing shows only the domain (measured). Removing the domain brings the
address back. A settings view that mirrors the listing therefore cannot show — or delete —
the individual entry while the domain is there.

**Suggestion:** list both; the client can show the address as implied by the domain.

### 25. A settings refresh is 25 requests with no batch form

**Where:** `GET /api/preferences/{key}` (one key per request), `GET /api/accounts/{id}/quota`
**Kind:** cost · **Impact:** medium on every launch
**Found by:** WS-21, timing a full server-state refresh against the live server

Every Mail route costs ~210 ms of PHP bootstrap on the test server; fifteen of the 25
requests a native client needs to mirror the settings the web client gets in its page state
are one preference each; and the quota route opens an IMAP session, 2.4 s on its own.
Serially 7.3 s, four at a time 2.6–3.1 s.

**Suggestion:** `GET /api/preferences` returning every user preference at once, which is
what `PageController::index` already assembles for the web client.

### 26. "Recently contacted" refuses `sync-collection`

**Where:** `/remote.php/dav/addressbooks/users/{u}/z-app-generated--contactsinteraction--recent/`
**Kind:** protocol · **Impact:** low, a full listing every pass
**Found by:** WS-24, mirroring every address book of the test login

The book is listed with no `sync-token` (404 in the PROPFIND), and a `sync-collection`
REPORT on it answers **415** `Sabre\DAV\Exception\ReportNotSupported`. Multiget works. A
mirror has to fall back to a Depth-1 ETag listing of the whole book on every pass.

**Suggestion:** implement `ISyncSupport` for the contacts-interaction book (it already keeps
per-card ETags), so clients can use the one sync protocol everywhere.

### 27. The default scheduling calendar is on the principal, and the birthday calendar does not say it is read-only

**Where:** `PROPFIND` on `/remote.php/dav/principals/users/{u}/` and on the calendar home
**Kind:** protocol · **Impact:** low, each costs a client an extra probe
**Found by:** WS-24, building the calendar list

`schedule-default-calendar-URL` answers 404 on the schedule inbox, where RFC 6638 §9.2 puts
it, and 200 on the principal. The birthday calendar answers `oc:read-only` 404 although it
is read-only; only `current-user-privilege-set` (no `write-content`) tells. Both measured.

**Suggestion:** also answer the property on the inbox; set `oc:read-only` on the birthday
calendar as on shared read-only ones.

### 28. Ten address books an hour, then 429

**Where:** extended `MKCOL` under `/remote.php/dav/addressbooks/users/{u}/`
**Kind:** limit · **Impact:** medium for test tooling, none for users
**Found by:** WS-24, re-running the fixture recorder's scratch lifecycles

After about ten creations in an hour, `MKCOL` answers **429**
`OCA\DAV\Connector\Sabre\Exception\TooManyRequests` ("Too many addressbooks created"), and
every request into the would-be book then answers 404. The limit is the dav app's
`rateLimitAddressBookCreation` (default 10 per `rateLimitPeriodAddressBookCreation`, 3600 s).
A full recorder run creates three scratch books, so three runs in an hour exhaust it. The
test server's limit was raised for WS-24's recording and restored afterwards.

**Suggestion:** none for the server — the limit is sensible. Recorder authors: reuse one
scratch book per run.

### 29. No translation provider is an empty language list on one route and a 412 on the other

**Found by:** WS-30, live 2026-10-04.
`GET /ocs/v2.php/translation/languages` on a server with no provider answers 200
`{"languages":[],"languageDetection":false}`, and `POST /ocs/v2.php/translation/translate`
answers OCS **412** "No translation provider available". The mail app's own
`llm_translation_enabled` is the only signal that the feature is off, and it has no
user-readable source (server-flags.md). A client that hides Translate on an empty language
list hides it on every server that simply lists no pairs yet; one that shows it gets a 412.
WS-30 shows the action unless the login row says it is off, builds its language pickers from
`Locale`, and turns the 412 into a `failed` row ("The message could not be translated").

**Suggestion:** expose `llm_translation_enabled` (or the provider's presence) on a route a
user can read, e.g. the mail preferences or capabilities.

### 30. `dkimValid` is null in every mirrored body, so the web's unsubscribe gate cannot be applied

**Found by:** WS-30.
The web client shows **Unsubscribe** only when `dkimValid` is true. `GET /api/messages/{id}/body`
leaves it null unless DKIM was verified by the separate `GET /api/messages/{id}/dkim` call,
which a mirror would have to make once per message. WS-30 applies "not known bad"
(`dkimValid != false`) instead and documents the deviation in ux-spec.md; the one-click
request is still made by the server, through the queue.

**Suggestion:** verify DKIM when the body is built (it is cached server-side already), or put
the verdict on the envelope.

### 31. An SMTP refusal parks the message in the outbox as status 10, with `failed` still false

**Found by:** WS-27's live re-verification, 2026-10-04 (from 12:12:47Z onwards).
Every `POST /api/outbox/{id}` to the account's own address answered **500** "Could not send
message"; the server log has `Horde_Mime_Exception` "Insufficient system storage" (code 6) from
`MailTransmission::send` — the relay's SMTP 452 4.3.1, Postfix's wording for a queue disk
running low, so an upstream condition rather than a rate limit. The message stays in the
outbox with `status` 10 (`STATUS_SMPT_SEND_FAIL`) and `failed: false`, and cron retries it
against the same relay. The client behaves as designed: the draft row is gone once
`from-draft` succeeded, the failure is logged, and the mirrored Outbox shows the message.
`ComposerLiveTests` deletes its own parked message and cancels with this reason when it sees
status 10, so delivery is unverifiable rather than red while the relay refuses.

**Suggestion:** set `failed` (or expose the SMTP reply) when the transport refuses, so a
client can tell "will retry" from "the relay said no" without knowing the status table.

### 32. `GET /api/mailboxes/{id}/messages` answers 409 while any sync of the mailbox runs

**Found by:** WS-27's live re-verification.
`MailSearch::findMessages` throws `MailboxLockedException` (409, "{id} is already being
synced") whenever the mailbox holds any of its three sync locks — including one taken by a
different client or the background job, for up to `Mailbox::LOCK_TIMEOUT`. A read that does
not touch IMAP is refused because a writer is busy, and nothing (no `Retry-After`) says when to
ask again. Right after a send, the client's own sync of Sent and a test's probe of Sent collide
this way; the live tests now treat 409 as "ask again".

**Suggestion:** serve the cached list while a sync runs (it is consistent per transaction), or
answer with `Retry-After`.

### 33. The mail-server update answers a half-empty account

**Found by:** WS-39, live 2026-10-04 (fixtures `account-updated.json` and `account.json`).
`PUT /api/accounts/{id}` answers `order`, `editorMode` and every special-mailbox id
(`draftsMailboxId`, `sentMailboxId`, `trashMailboxId`, `junkMailboxId`, …) as **null**, while
the stored account keeps them — the next `GET /api/accounts/{id}` has them all.
`AccountsController::update` returns `SetupService::createNewAccount(…, $id)`, which builds a
fresh `MailAccount` from the request's connection fields only (`lib/Service/SetupService.php`,
`new MailAccount([...])` then `save`) and serialises that, not the row the update produced.
`create` returns the same serialiser's answer. A client that upserts the answer wipes the
account's writing mode and default folders; `SettingsCommands` re-reads the account with a
GET after both the PUT and the POST, and trusts only the POST's `id`.

**Suggestion:** return `accountService->find($userId, $id)` after the save, as `show` does.

### 34. A PUT refused for a UID conflict has already sent the scheduling REPLY

**Found by:** WS-34, live 2026-10-04 (ADR-0093; fixture `dav-error-uid-conflict-ws34.xml`).
Scheduling delivers a same-server invitation into the attendee's default calendar as
`sabredav-<uuid>.ics`. An attendee client that writes its answer under its own name gets 409
`no-uid-conflict` — but the organiser's copy has already flipped and a REPLY sits in their
schedule inbox: Sabre's scheduling runs before `CalDavBackend` checks the UID (a TENTATIVE
probe through a 409 moved the organiser's PARTSTAT while the attendee's copy stayed
unchanged). The client's follow-up write onto the existing copy sends a second identical
REPLY. So a refused request has a side effect, and organiser and attendee can disagree.

**Suggestion:** check UID uniqueness before scheduling (or roll the scheduling back on the
conflict).

### 35. The REPLY drops the attendee's comment

**Found by:** WS-34, live 2026-10-04. The web client (and this one) writes the participation
comment as `X-RESPONSE-COMMENT` on the ATTENDEE line and as COMMENT. The attendee's copy keeps
both; the REPLY in the organiser's schedule inbox, and the organiser's copy, carry PARTSTAT and
CN only. The organiser never sees "See you there" for a same-server invitation.

**Suggestion:** carry `X-RESPONSE-COMMENT` (and COMMENT, per RFC 5546 §3.2.3) into the REPLY.

### 36. Circles hands back a group member as a team, and takes its level under a different key

**Found by:** WS-37, live 2026-10-04 (Circles 36.0.0-dev; fixture `circle-members-ws37.json`).
`POST /ocs/v2.php/apps/circles/circles/{id}/members {"userId":"admin","type":2}` adds the
group; `GET …/members` then reports it as `userType` 16 (team), with the group only in
`basedOn.source` 2. A user and a group with the same name are two members whose `userId` is
the same string. And every Circles setter takes `{value}` (`name`, `description`, `config`)
except `PUT …/members/{memberId}/level`, which takes `{level}` and ignores `value`.

**Suggestion:** report the type the member was added as (or document `basedOn.source` as the
one to read), and accept `value` on the level route like its siblings.

### 37. "Shared items" depends on an app a default server does not have

**Found by:** WS-37, live 2026-10-04. Web Contacts' contact panel "Media shares / Talk /
Calendar / Deck with you" calls `GET /ocs/v2.php/apps/related_resources/related/account`.
`related_resources` is not shipped with the server; on the test server the route answers OCS
998 "Invalid query" and the web panels hide themselves, so web Contacts shows "No shared items
with this contact" even for a user with whom files are shared. This client reads the
files_sharing listings instead, which every server has (ADR-0097).

**Suggestion:** web Contacts could fall back to the files_sharing listing when
`related_resources` is absent, or say that the panel needs the app.

## Deliberate behaviour that looks like a bug, and should be documented as deliberate

### 14. The 1x1 tracking pixel is unrecoverable, which is right

**Where:** `lib/Service/HtmlPurify/TransformImageSrc.php`
**Found by:** WS-09, on the same recorded body as finding 5

Nine of the ten images in `message-html-plain.html` carry a `data-original-src`. The tenth,
`width="1" height="1"` with no alt, carries none: the server replaced its `src` and kept
nothing. So **Show images** cannot restore it, no client-side rule is needed to keep it
blocked, and a reader who unblocks a newsletter still does not confirm receipt to its
tracker.

Worth writing down because it looks like an inconsistency in the payload and it is a
deliberate, load-bearing one. A client author who "fixes" it by keeping the original URL
would quietly undo it.

**Suggestion:** one sentence in the OpenAPI spec or the transform's doc block, so the next
client author knows it is a feature.

---

## Things that are right, and worth saying

- **The server sanitises HTML and blocks remote images before the client sees them**
  (`lib/Service/HtmlPurify/TransformImageSrc.php`). That is what lets this client mirror
  40,000 messages without firing a single tracking pixel, and it means no MIME parser and no
  sanitiser in our codebase. Finding 5 is a gap in this, not an argument against it.
- **`?plain=true` on the HTML endpoint** returns exactly what a native client wants: the
  fragment, without the iframe resizer. Someone thought about a non-browser consumer.
- **`init: true` and the 428** make "the server has not cached this mailbox yet" an
  explicit, handleable state rather than an empty list that a client has to guess about.
- **`#[NoCSRFRequired]` on the avatar and proxy endpoints** makes them usable with
  app-password auth, which is what makes avatars and image unblocking work at all.
