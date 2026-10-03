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
