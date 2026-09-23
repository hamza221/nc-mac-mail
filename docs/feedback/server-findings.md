<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Nextcloud Mail server findings

*What building a native, mirroring client found in `nextcloud/mail`. Every entry cites a
file, because an uncited finding cannot be acted on.*

Version examined: **5.12.0-rc.1** (`appinfo/info.xml`), `main`.

Nothing here is a complaint about a bad API. All of it is an API designed for one client — a
Vue app that shows a page of mail at a time — meeting a second client with different needs.
That is what the exercise was for.

**Append as you go.** WS-15 turns this into upstream issues for a human to post.

---

## 1. No bulk body endpoint

**Where:** `lib/Controller/MessagesController.php::getBody`
**Kind:** design-for-browsers · **Impact:** high for any mirroring client

`GET /api/messages/{id}/body` opens an IMAP connection, fetches one message, parses and
sanitises it. Mirroring a 50,000-message account therefore means 50,000 of those. The client
handles it with bounded concurrency, newest-first ordering, backoff and pausing
([ADR-0003](../decisions/0003-local-first-full-mirror.md)), but it is the single largest
cost of a native client.

**Suggestion:** `POST /api/messages/bodies` taking up to ~50 ids and returning them in one
response, reusing one IMAP connection. Cuts round trips by a factor of fifty and lets the
server control the batch size, which is better for everyone than a client guessing.

## 2. `POST /sync` returns every id you claim to know

**Where:** `lib/Service/Sync/SyncService.php::getDatabaseSyncChanges` — the method carries
its own `// TODO: $changed = $this->messageMapper->findChanged(...)`
**Kind:** known gap · **Impact:** high

`changedMessages` is every id in the request that still exists, in full. There is no change
detection. A client that knows a lot must therefore send a small window and accept blind
spots outside it ([ADR-0015](../decisions/0015-bounded-sync-window.md)).

**Suggestion:** implement the `TODO`, or add a `since` token so a client can ask "what
changed since X" instead of describing what it has.

## 3. `newMessages` only contains thread heads

**Where:** `lib/Db/MessageMapper.php::findNewIds` — self-join on `thread_root_id`,
`m2.id IS NULL`
**Kind:** probably unintended for this endpoint · **Impact:** high

Threaded-view filtering is applied to a **sync** response. Two new messages in one thread
and a client hears about one. For a list that renders thread heads this is invisible; for a
mirror it is silent data loss, and it forces every mirroring client to page the message list
after each sync as a safety net.

**Suggestion:** return all new messages from `sync` regardless of threading, and let the
client group. Threading is a display concern; sync is not display.

## 4. Two names for the destination mailbox

**Where:** `lib/Controller/MessagesController.php:379` (`destFolderId`) versus
`lib/Controller/ThreadController.php:55` (`destMailboxId`)
**Kind:** inconsistency · **Impact:** low, but it will cost every new client an afternoon

**Suggestion:** accept both on both, deprecate one.

## 5. `flags` is an object on the envelope and an array on the body

**Where:** `lib/Db/Message.php::jsonSerialize` versus `lib/Model/IMAPMessage.php::jsonSerialize`
**Kind:** inconsistency · **Impact:** low, one extra model in every typed client

**Suggestion:** one shape. The object form is more useful.

## 6. `selectable` is computed and then not serialised

**Where:** `lib/IMAP/MailboxSync.php:220` sets it; `lib/Db/Mailbox.php::jsonSerialize` omits it
**Kind:** omission · **Impact:** low

Clients re-derive it from `attributes` containing `\noselect`. Subscription is the same
story: `\subscribed` in `attributes`, with the Vue client lowercasing before comparing
(`src/components/NavigationMailbox.vue:289`), so every client must know to do the same.

**Suggestion:** serialise `selectable` and `subscribed` as booleans. The information is
already computed.

## 7. `displayName` is the full IMAP path

**Where:** `lib/Db/Mailbox.php::jsonSerialize` — `'displayName' => $this->getName()`
**Kind:** naming · **Impact:** low

Every client splits it on the delimiter to get something displayable, which means every
client reimplements the same function.

**Suggestion:** make `displayName` the leaf, or add `leafName`.

## 8. `specialRole` can be the integer 0

**Where:** `lib/Db/Mailbox.php::jsonSerialize` — `'specialRole' => $specialUse[0] ?? 0`
**Kind:** typing · **Impact:** low, but it breaks strict decoders

**Suggestion:** `null` instead of `0`.

## 9. `mailbox.id` is base64 of the name

**Where:** same method — `'id' => base64_encode($this->getName())`
**Kind:** naming · **Impact:** medium for a newcomer

A field called `id` that is not the identifier, next to `databaseId` which is, next to an
always-empty `mailboxes` array that looks like it should hold the hierarchy. Three traps in
one payload, and each one is discovered by a bug.

**Suggestion:** document it in the OpenAPI spec at minimum. Renaming would be a breaking
change, but the docs are free.

## 10. Sort order is a server-side user preference, not a parameter

**Where:** `lib/Controller/MessagesController.php::index` reads the `sort-order` preference
**Kind:** design · **Impact:** medium

`cursor` semantics change with a preference set in another client. A client that does not
read `GET /api/preferences/sort-order` first will paginate in the wrong direction and not
know why.

**Suggestion:** accept `sortOrder` as a parameter, defaulting to the preference.

---

## 11. `GET /api/messages`'s `cursor` is strictly exclusive, so a duplicate `dateInt` at a page boundary is unreachable

**Where:** `lib/Controller/MessagesController.php::index`, `lib/Db/MessageMapper.php::findIdsByQuery`
**Kind:** correctness · **Impact:** high

`cursor` is a `dateInt`, and the comparison is `<`. Verified against Mail 5.12.0-rc.1:
`GET /messages?mailboxId=5&view=singleton&limit=3` ends at `dateInt` 1789590490, and
`&cursor=1789590490` returns only messages older than it, never it.

Two messages can share a `dateInt` — the test account's inbox has ids 44 and 45 both at
1778515439 — and `dateInt` is second resolution, so on a busy mailbox this is common rather
than exotic. When a page's `limit` falls between two such messages, the client sends the
first one's `dateInt` as the cursor and the second becomes unreachable by pagination.
There is no error, no gap in the count the client can see, and no second chance: every
subsequent page is strictly older.

A client can work around it by sending `oldest dateInt + 1` and tolerating one duplicated
row per page, which is what this client does
([ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md)). It should not have to, and a
client that reads the parameter's name and does the obvious thing loses mail silently.

**Suggestion:** make the cursor a `(dateInt, id)` pair, or document the `+ 1`. The web
client does not hit this because it never enumerates a whole mailbox.

## 12. The wall-clock cost of a backfill is the IMAP fetch, and it varies eightfold

**Where:** `lib/Controller/MessagesController.php::getBody`
**Kind:** performance · **Impact:** medium

Measured by mirroring a 155-message account three times with identical code, two body
fetches in flight: 183 s, 213 s and 1,498 s. The request count is the same every time; what
moves is how long `/body` takes to open an IMAP connection, fetch, parse and sanitise.

This is the number behind the bulk-body ask in finding 1. A client cannot make it smaller by
being politer — it is already inside the concurrency budget — and at 1.4 s per message a
50,000-message account is 19 hours of somebody's server doing one message at a time.

## 13. The message list's sort order is a stored preference, and it silently inverts pagination

**Where:** `lib/Controller/MessagesController.php::index`, `lib/Db/MessageMapper.php`
**Kind:** correctness · **Impact:** high for any client that enumerates

`GET /api/messages` takes no sort-order parameter. It reads the user's stored `sort-order`
preference, and that one value changes two things at once: which end of the mailbox page one
comes from, and which way `cursor` compares.

Measured on a live 5.12.0-rc.1 instance, setting the preference and putting it back:

| | `newest` / unset | `oldest` |
| --- | --- | --- |
| `limit=5` | ids 167, 166, 165, 164, 154 — newest first | ids 23, 24, 25, 26, 27 — oldest first |
| `cursor=<dateInt>` | returns messages **older** than it | returns messages **newer** than it |
| `&sortOrder=newest` in the query | ignored | ignored |

Two consequences for a client that mirrors a whole mailbox. Pagination arithmetic has to
flip with a value it did not send and cannot override per request — the workaround for
finding 11 becomes `newest dateInt - 1` instead of `oldest dateInt + 1`. And a
"page from the newest until you recognise everything" scan, which is how this client catches
the thread siblings `POST /sync` omits (finding 3), cannot be expressed at all: under
`oldest` the newest messages are at the far end of the walk.

The failure is silent in the worst way. Nothing errors; the enumeration just advances by one
row per page instead of by a hundred, so a mailbox that took 500 requests takes 50,000 and
looks like a slow server.

**Suggestion:** accept `sortOrder` as a query parameter on `GET /api/messages`, as
`POST /sync` already does in its body. It is one line in the controller and it would let a
client ask for what it needs without touching a user-visible preference.

---

## Things that are right, and worth saying

- **The server sanitises HTML and blocks remote images before the client sees them**
  (`lib/Service/HtmlPurify/TransformImageSrc.php`). That is what lets this client mirror
  40,000 messages without firing a single tracking pixel, and it means no MIME parser and
  no sanitiser in our codebase.
- **`?plain=true` on the HTML endpoint** returns exactly what a native client wants: the
  fragment, without the iframe resizer. Someone thought about a non-browser consumer.
- **`init: true` and the 428** make "the server has not cached this mailbox yet" an explicit,
  handleable state rather than an empty list.
- **`#[NoCSRFRequired]` on the avatar and proxy endpoints** makes them usable with app-password
  auth, which is what makes avatars and image unblocking work at all.

---

## 14. `TransformImageSrc` rewrites `<img>` and not CSS, so `@import` survives sanitisation

**Found by:** WS-09, rendering the recorded body.

`lib/Service/HtmlPurify/TransformImageSrc.php` replaces every remote `<img src>` with the
blocked placeholder and stashes the original in `data-original-src`. HTMLPurifier keeps
`<style>` blocks, and nothing in the chain touches the URLs inside them. The recorded body
`message-html-plain.html` — a real marketing email, nine images blocked, a 1×1 tracking
pixel neutralised — opens its `<style>` with:

```css
@import url(https://static-forms.klaviyo.com/fonts/api/v1/U45QAK/custom_fonts.css);
```

A browser rendering that fragment fetches it. It is a fourth host, it is not blocked, and it
is a request that tells the sender's font CDN when the message was opened, from where. The
web client renders the fragment in an iframe with a CSP, which may or may not stop it
depending on the policy; a native client with no CSP has nothing in the way.

**What we do:** delete every `@import` and rewrite every `url(…)` through the same
allowlist as `<img>` ([ADR-0039](../decisions/0039-a-rendered-message-holds-only-urls-we-would-fetch.md)).
Messages lose web fonts and CSS background images that the server would have proxied
happily.

**Suggestion:** extend the transformation to CSS `url()` and `@import`, either by dropping
them or by routing them through `/proxy` the way images go. The proxy already exists and
already signs its URLs; this is the same treatment for the other half of the document.

## 15. The 1×1 tracking pixel is genuinely unrecoverable, which is the right behaviour

**Found by:** WS-09, on the same body.

Nine of the ten images in the recorded body carry a `data-original-src`. The tenth —
`width="1" height="1"`, no alt — carries none: the server replaced its `src` and kept
nothing. So **Show images** cannot restore it, there is no client-side rule needed to keep
it blocked, and a reader who unblocks a newsletter still does not confirm receipt to its
tracker. Worth writing down because it looks like an inconsistency in the payload and it is
a deliberate, load-bearing one.
