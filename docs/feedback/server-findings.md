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
