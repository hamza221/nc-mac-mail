<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# API payloads and semantics

*The exact shapes this app decodes, and the endpoint behaviour that is not obvious from the
shapes. Every claim cites `nextcloud/mail` at app version 5.12.0-rc.1.*

**Verified against a live server by WS-02**, Nextcloud 36.0.0 running Mail 5.12.0-rc.1, in
September 2026. Where the reading of the source and the running server disagreed, the
server won and the paragraph was rewritten; each of those is marked **corrected**. The
recorded responses are in
`Packages/NCMailTestSupport/Sources/NCMailTestSupport/Resources/Fixtures/`.

The complete endpoint map — including everything v1 does not use — is
[../../plan/API.md](../../plan/API.md). This document covers only what v1 touches, plus the
traps.

## Read this first: the six traps

Each has already been designed around. They are collected here because each one costs a day
if it is met in a debugger instead of a document.

**1. `view=threaded` returns one message per thread.** Not a display hint — the query joins
the message table to itself on `thread_root_id` and keeps rows with no newer sibling
(`lib/Db/MessageMapper.php::findIdsByQuery`). Enumerate with `view=singleton` or silently
lose every reply. [ADR-0014](../decisions/0014-singleton-enumeration.md)

Measured: the test server's inbox of 95 messages returns 95 envelopes with `view=singleton`
and 87 with `view=threaded`. Eight replies, gone, with a 200.

**2. `POST /sync`'s `ids` is a window, not an inventory.** "New" means not in `ids` *and*
newer than the oldest `sent_at` among them. `changedMessages` returns every id you sent
that still exists — there is no change detection, and the source says so in a `TODO`.
`vanishedMessages` is `array_diff(yourIds, stillExisting)`, so nothing you did not claim to
know can ever be reported vanished (`lib/Service/Sync/SyncService.php::getDatabaseSyncChanges`).
[ADR-0015](../decisions/0015-bounded-sync-window.md)

**3. `newMessages` from `POST /sync` only contains thread heads.** Same self-join as trap 1,
in `findNewIds`. Two new messages in one thread, and you hear about one. Hence the tail
scan.

**4. Two names for one parameter.** `POST /api/messages/{id}/move` takes `destFolderId`
(`lib/Controller/MessagesController.php:379`). `POST /api/thread/{id}` takes
`destMailboxId` (`lib/Controller/ThreadController.php:55`). Same concept, same value, two
spellings.

**5. `GET /messages`'s `cursor` is strictly exclusive, and `dateInt` is not unique.**
Added by WS-04 after mirroring the live account. The comparison is `<`, verified: a page
ending at `dateInt` 1789590490 followed by `&cursor=1789590490` returns only messages older
than it. Two messages can share a `dateInt` — the test inbox has ids 44 and 45 both at
1778515439 — so when a page boundary falls between them, the second is unreachable by
pagination, with no error and no gap anyone can see. Send **`oldest dateInt + 1`** and let
the boundary message repeat; the upsert finds the row it already has through
`(accountId, remoteId)`, so it costs nothing.
[ADR-0030](../decisions/0030-stage-one-owns-its-cursor.md), and finding 11 in
[../feedback/server-findings.md](../feedback/server-findings.md).

**6. The user's `sort-order` preference decides what page one is and which way `cursor`
points.** Added by WS-05, measured by setting the preference on the live server and putting
it back. With `sort-order` unset or `newest`, page one of `GET /messages` is the newest 100
and `cursor` is an exclusive **upper** bound (`dateInt <`). With it set to `oldest`, page one
is the **oldest** 100 and `cursor` becomes an exclusive **lower** bound: `&cursor=1776198096`
— the `dateInt` of the oldest message — returned the messages *newer* than it. There is no
way to override it per request: `&sortOrder=newest` in the query is ignored, because
`MessagesController::index` reads the preference and not the parameter.

So a client that enumerates with `oldest dateInt + 1` (trap 5) walks forward by one row per
page under `oldest`, and a "page from the newest until you recognise everything" scan cannot
be expressed at all. The cursor has to flip to `newest dateInt - 1`, and the tail scan has to
be skipped. [ADR-0036](../decisions/0036-sort-order-decides-the-cursor.md), and finding 13 in
[../feedback/server-findings.md](../feedback/server-findings.md).

And one more, cheaper but sharp: **`mailbox.id` is not an id.** It is
`base64_encode(name)`. The numeric key every other endpoint wants is `databaseId`.

**Corrected.** This document used to warn, under [Message body](#message-body), that `flags`
is an object on the envelope and an array on the body, and the WS-02 brief repeated it as a
trap. It is an object on both. What the two really differ in is their keys, and that
section now says so.

## Account

`GET /api/accounts` → array; `GET /api/accounts/{id}` → one.
Source: `lib/Db/MailAccount.php::toJson`.

```jsonc
{
  "id": 3, "accountId": 3,
  "name": "Lorelai Gilmore",
  "emailAddress": "lorelai@dragonfly.example",
  "order": 0,
  "authMethod": "password",
  "imapHost": "imap.example", "imapPort": 993, "imapUser": "…", "imapSslMode": "ssl",
  "smtpHost": "…", "smtpPort": 587, "smtpUser": "…", "smtpSslMode": "tls",  // absent if no outbound host
  "signature": "…", "signatureMode": 0, "signatureAboveQuote": false,   // signatureMode is an INTEGER
  "editorMode": "richtext",
  "provisioningId": null,
  "showSubscribedOnly": false,
  "personalNamespace": null,
  "draftsMailboxId": 12, "sentMailboxId": 13, "trashMailboxId": 14,
  "archiveMailboxId": 15, "snoozeMailboxId": null, "junkMailboxId": 16,
  "sieveEnabled": false,
  "smimeCertificateId": null,
  "quotaPercentage": 42,
  "trashRetentionDays": 60,
  "searchBody": false,
  "outOfOfficeFollowsSystem": false,
  "debug": false,
  "classificationEnabled": true,
  "imipCreate": true,
  "protocol": "imap",
  "path": null,
  "aliases": [],                     // present on 5.12; absent from earlier revisions of this document
  "isDelegated": false
}
```

v1 needs: `id`, `name`, `emailAddress`, `order`, and the six special mailbox ids. The rest
is stored in `account.rawJSON` against future use.

**Corrected.** `signatureMode` is an integer, not null, and the payload also carries
`aliases` and `isDelegated`. `trashRetentionDays` is null on an account that never set one.
None of it is modelled; all of it survives in `rawJSON`.

Special mailbox ids may be `null` on a freshly provisioned account — and on an
established one: the test account has no archive mailbox at all, so `archiveMailboxId` is
null against a server that has been in use for months. Triage actions that
depend on one (archive, junk) must be disabled rather than crash — and that state is worth
a decent empty-state message, not a greyed button with no explanation.

**Create/update refused by IMAP or SMTP** (`POST /api/accounts`, `PUT /api/accounts/{id}`;
`CouldNotConnectException`, recorded live 2026-10-04 as
`error-account-create-wrong-password.json` / `error-account-create-unreachable.json`):
HTTP 400, `{"status":"fail","data":{"error":"AUTHENTICATION_WRONG_PASSWORD","service":"IMAP","host":"…","port":993}}`.
`error` is one of `CONNECTION_ERROR`, `AUTHENTICATION`, `AUTHENTICATION_WRONG_PASSWORD`,
`AUTHENTICATION_DENIED`, `OTHER`; `service` is `IMAP` or `SMTP`. `MailClient` maps it to
`MailError.connectFailed(service:reason:)`; the setup sheet's §1.5 strings key off both.
An `authMethod: "xoauth2"` create is not connection-tested: it succeeds, and
`GET /api/accounts/{id}/test` answers `{"data":false}` until the OAuth token lands.

## Mailbox

`GET /api/mailboxes?accountId=` →
`{"id": <accountId>, "email": "…", "mailboxes": [...], "delimiter": "."}`.
Source: `lib/Db/Mailbox.php::jsonSerialize`.

```jsonc
{
  "databaseId": 42,                  // ← the id every other endpoint wants
  "id": "SU5CT1guV29yaw==",          // base64 of name. Not an id. Ignore it
  "name": "INBOX.Work",              // full IMAP path
  "accountId": 3,
  "displayName": "INBOX.Work",       // NOT the leaf name — see below
  "attributes": ["\\subscribed", "\\haschildren"],
  "delimiter": ".",
  "specialUse": ["inbox"],
  "specialRole": "inbox",            // specialUse[0] ?? 0 — can be the integer 0
  "mailboxes": [],                   // always empty; the list is flat
  "syncInBackground": true,
  "unread": 7,
  "myAcls": "rliteswkxpa",           // a string when the server reports ACLs; null when it does not
  "shared": false,
  "cacheBuster": "…"
}
```

Four things to handle:

- **`displayName` is the full path**, not the leaf. The tree builder splits `name` on
  `delimiter` and takes the last component itself.
- **`mailboxes` is always empty.** The hierarchy is in the names. `MailboxTree` builds it.
- **Subscription lives in `attributes`** as `\subscribed`, compared case-insensitively —
  Horde passes server casing through and the Vue client lowercases
  (`src/components/NavigationMailbox.vue:289`). Same array carries `\noselect`, which means
  the mailbox cannot be opened; the `selectable` column exists server-side but is **not**
  serialised, so derive it. [ADR-0007](../decisions/0007-subscribed-mailboxes-only.md)
- **`specialRole` is `specialUse[0] ?? 0`**, so it is a string or the integer `0`. Decode
  it leniently. Confirmed live: two of the test server's seven folders send the integer.
  The integer means *no role*, not the role `"0"`.

## Message envelope

From `GET /api/messages`, and inside every `POST /sync` response.
Source: `lib/Db/Message.php::jsonSerialize`.

```jsonc
{
  "databaseId": 90210,
  "uid": 4711,
  "remoteId": "…",
  "subject": "The Dragonfly opening menu",
  "dateInt": 1737100000,             // unix seconds; also the pagination cursor
  "flags": {
    "seen": false, "flagged": true, "answered": false, "deleted": false,
    "draft": false, "forwarded": false, "hasAttachments": true,
    "important": false, "$junk": false, "$notjunk": false, "$mdnsent": false
  },
  "tags": { "$label1": { "id": 1, "userId": "…", "displayName": "Important",
                         "imapLabel": "$label1", "color": "#ff0000", "isDefaultTag": true } },
                                      // …or [] — see below
  "from": [{ "label": "Sookie St. James", "email": "sookie@dragonfly.example" }],
  "to": [...], "cc": [...], "bcc": [...],
  "mailboxId": 42,
  "messageId": "<abc@dragonfly.example>",
  "inReplyTo": null,
  "references": null,                 // null or an array
  "threadRootId": "…",
  "imipMessage": false,
  "mentionsMe": 0,                    // an INTEGER 0 or 1, not a boolean
  "previewText": "I moved the risotto…",
  "summary": null,
  "encrypted": false,
  "avatar": { "isExternal": false, "mime": "image/jpeg", "url": "…" },   // or null
  "fetchAvatarFromClient": false,
  "attachments": []                   // the REDUCED attachment shape — see Message body
}
```

- **`flags` keys include `$junk`, `$notjunk`, `$mdnsent`** — leading `$`, so
  `CodingKeys` must spell them explicitly.
- **`tags` is a dictionary keyed by IMAP label**, not an array — *except* when it is empty.
  **Corrected:** PHP serialises an empty associative array as `[]`, so an envelope with no
  tags sends `"tags": []` and one with tags sends an object. Seven of the 95 envelopes in
  `messages-inbox-page1.json` take the array form. A decoder that only accepts an object
  fails on a perfectly ordinary message.
- **`mentionsMe` is the integer `0` or `1`**, not a boolean. **Corrected:** it is written by
  a `COUNT(*)` and never cast.
- **`dateInt` is the cursor** for `GET /api/messages`: pass the oldest one you have seen.
- **`references` is `null` or an array**, never a string. Always an array on 5.12.
- **`remoteId` is null** on every envelope the test server produced; treat it as optional.
- **`attachments` inside an envelope is the reduced shape**: `id`, `fileName`, `mime`,
  `downloadUrl`, `mimeUrl`, and nothing else. `enrichAttachment` runs only on the body.

## Message body

`GET /api/messages/{id}/body`. Source: `MessagesController::getBody` +
`lib/Model/IMAPMessage.php::getFullMessage`.

```jsonc
{
  "uid": 4711, "messageId": "<…>", "subject": "…", "dateInt": 1737100000,
  "from": [...], "to": [...], "cc": [...], "bcc": [...], "replyTo": [...],
  "flags": {...},                     // an OBJECT, same as the envelope — see below
  "hasHtmlBody": true,
  "body": "<div>…</div>",             // sanitised HTML, or plain text when hasHtmlBody is false
  "signature": "…",                   // plain-text messages only
  "attachments": [...], "inlineAttachments": [...],
  "dispositionNotificationTo": null,
  "hasDkimSignature": true,           // "dkimValid" appears only after GET .../dkim has run
  "phishingDetails": {...},
  "unsubscribeUrl": null, "unsubscribeMailto": null, "isOneClickUnsubscribe": false,
  "scheduling": [...],
  "replyTo": [...],
  "isPgpMimeEncrypted": false,
  "hasAiGeneratedHeader": false,
  "itineraries": [...],               // only when cached
  "accountId": 3, "mailboxId": 42, "databaseId": 90210,
  "isSenderTrusted": false,
  "smime": { "isEncrypted": false, "isSigned": false, "signatureIsValid": null }
}
```

**Corrected: `flags` is an object here too.** An earlier revision of this document said it
was an array. Against Mail 5.12.0-rc.1 — the version this document cites —
`GET /api/messages/{id}/body` returns

```json
{"seen":true,"flagged":false,"answered":false,"deleted":false,"draft":false,
 "forwarded":false,"hasAttachments":true,"$mdnsent":false,"important":true}
```

`IMAPMessage::getFlags()` builds a PHP associative array, and an associative array is a
JSON object. What the two responses really differ in is their **keys**: the body omits
`$junk` and `$notjunk`, which the envelope has. So one model covers both, with those two
defaulting to false, and a decoder that requires them fails on every body.

Also **corrected**: `signature`, `dkimValid` and `itineraries` are documented above but do
not appear at all unless the feature that produces them has run. `replyTo` does appear and
was missing from the list. Treat all four as optional.

Attachment entries come in two shapes, and only the body's is the full one.

```jsonc
// GET /api/messages/{id}/body — enrichAttachment has run
{ "id": "2", "messageId": 48, "fileName": "menu.pdf", "mime": "application/pdf",
  "size": 183422, "cid": "f_mquymsb20", "disposition": "attachment",
  "downloadUrl": "https://…", "mimeUrl": "…", "isImage": false, "isCalendarEvent": false }

// inside an envelope — five keys, and that is all
{ "id": "2", "fileName": "menu.pdf", "mime": "application/pdf",
  "downloadUrl": "https://…", "mimeUrl": "…" }
```

`id` is a **string** (`"2"`, `"2.1"`), not a number.

**Corrected**, twice. The envelope's reduced shape was not documented, so `size`, `cid`,
`disposition`, `isImage` and `isCalendarEvent` all have to be optional. And `messageId` on
the body shape is the **IMAP uid**, not the `databaseId` the surrounding payload uses — the
attachment of message 66 reports `"messageId": 48`. It is not a key to look a message up by.

## Message HTML

`GET /api/messages/{id}/html?plain=true` → `text/html`, **not JSON**.

With `plain=true` the server returns the sanitised fragment alone. Without it, the fragment
is wrapped in a document containing an iframe-resizer script and a CSP nonce
(`lib/Http/HtmlResponse.php`). Always pass `plain=true`; we build our own shell
([../architecture/rendering.md](../architecture/rendering.md)).

Remote images arrive already blocked
(`lib/Service/HtmlPurify/TransformImageSrc.php`):

```html
<img src="/apps/mail/img/blocked-image.png"
     data-original-src="…/apps/mail/proxy?src=…&id=…&hmac=…"
     data-original-style="…"
     style="…;display:none!important">
```

Tracking pixels (under 5×5 with explicit width and height) are replaced outright and are
not restorable — the server drops the original URL for those. Inline attachments carry
`data-cid` (`TransformCidDataAttr.php`).

## Sync

```http
POST /api/mailboxes/{id}/sync
{"ids": [90210, 90211], "lastMessageTimestamp": 1737000000, "init": false, "sortOrder": "newest", "query": null}
```

```jsonc
{ "newMessages": [envelope…], "changedMessages": [envelope…],
  "vanishedMessages": [90180, 90181], "stats": { "total": 1234, "unread": 7 } }
```

Traps 2 and 3 above. Statuses: **200** fine; **202** with a `fail` envelope means
`IncompleteSyncException` (still working, retry); **428** means the mailbox is not cached —
re-send with `init: true` (`lib/Controller/MailboxesController.php:186`).

Three more things WS-05 measured about this endpoint, none of them visible from the shape:

- **`vanishedMessages` is scoped to the mailbox, not to the account.** Sending the inbox's
  sync a message id that exists but lives in Sent Items reports that id vanished. So a
  message moved in the web client looks like "gone from the source" plus "new in the
  destination", which is what a mirror wants — but it means a local row is deleted and its
  body re-fetched under the destination's new id, because an IMAP move is a delete and an
  append and the server's `databaseId` changes with it.
- **`POST /sync` refreshes the server's IMAP cache as a side effect.** A sync sent against a
  95-message inbox came back with one `newMessages` entry, and the `GET /messages` that
  followed then returned 96 where the identical call a second earlier had returned 95. The
  enumeration endpoint reads the cache; the sync endpoint fills it.
- **`{"ids": [], "init": false}` returns the whole mailbox** as `newMessages`, exactly as
  `init: true` does — 96 of 96 on the test inbox. A client with nothing mirrored for a
  mailbox must not send an empty window on the incremental path, because the response is
  unpaginated.

Neither 202 nor 428 could be provoked on the test server: a sync against a mailbox that had
never been synced answered **200** with four empty arrays rather than 428. So the client
handles both statuses, and both paths are covered by fake-transport tests rather than by a
recorded fixture. If you can make a real server emit either, record it.

`lastMessageTimestamp` only affects the oldest-first sort order
(`MessageMapper::findNewIds`). With `sortOrder: "newest"` it is ignored; send it anyway for
forward compatibility.

## Messages list

```http
GET /api/messages?mailboxId=42&view=singleton&limit=100&cursor=1737000000
```

- `limit` clamped server-side to 1…100 (`MessagesController::index`). Confirmed: `limit=500`
  returns at most 100.
- `cursor` = `dateInt` of the oldest envelope received so far, and it is **exclusive**.
  Confirmed on a 95-message inbox: `limit=50` gives 50, then the same call with
  `cursor=<min dateInt>` gives the remaining 45 with no overlap and no repeat.
  `messages-inbox-page2.json` is `[]` for the boring reason that it was recorded at
  `limit=100` against those 95 messages, so page one already had everything. It is still a
  useful fixture: an empty page is how enumeration learns it is finished.
- `view`: `singleton` or `threaded` — trap 1.
- `filter` takes the search filter string (`plan/API.md`); v1 searches locally and does not
  use it, except in the one place noted in [../architecture/sync-engine.md](../architecture/sync-engine.md).
- Sort order comes from the user's server-side `sort-order` preference, **not** a
  parameter. A user who set "oldest first" in the web client changes what `cursor` means.
  Read `GET /api/preferences/sort-order` at startup and pass the matching `sortOrder` to
  sync.
- An uncached mailbox throws `MailboxNotCachedException` → **400** with a
  `{"status":"error"}` body. Prime with `init: true` first. Not reproduced on the test
  server, which answered 200 with `[]`; the 400 path is still handled.

## Mutations

| Action | Request | Body |
| --- | --- | --- |
| Flags | `PUT /api/messages/{id}/flags` | `{"flags": {"seen": true}}` |
| Move | `POST /api/messages/{id}/move` | `{"destFolderId": 15}` |
| Delete | `DELETE /api/messages/{id}` | — (trash, or erase when already in trash) |
| Move thread | `POST /api/thread/{id}` | `{"destMailboxId": 15}` ← different name |
| Delete thread | `DELETE /api/thread/{id}` | — |
| Trust sender | `PUT /api/trustedsenders/{email}?type=individual` | — |

Flag keys accepted by `setFlags`: `seen`, `flagged`, `answered`, `deleted`, `draft`,
`forwarded`, `junk`, `notjunk`, `mdnsent`, `important`. Note that the setter takes `junk`
while the envelope reports `$junk`.

`{id}` on the thread routes is *any* message id in the thread; the root is resolved
server-side.

## What a missing thing actually answers

**Corrected.** This document implied that a bad id produces the `JsonResponse::fail`
envelope. It does not. Against 5.12.0-rc.1 every one of these returns **HTTP 403** with a
body of exactly `[]`:

```
GET /api/mailboxes/99999999/stats   → 403  []
GET /api/messages/99999999          → 403  []
GET /api/messages/99999999/body     → 403  []
```

`DelegationService` resolves the effective user for every id before the controller runs, and
an id that does not exist cannot be resolved to one the caller may see, so "gone" and
"never yours" are the same answer. Two consequences. There is no message to parse, so a
client must not wait for one; and **403 does not mean the account lost its delegation** —
it is the ordinary answer to a stale id, which a mirror hands the server all the time after
someone deletes a message in the web client. Treat 403 as "this id is gone", not as a
reason to sign the user out.

`POST /api/mailboxes/{id}/sync` on a non-existent mailbox answers **405** with an HTML body,
because the route only matches an existing id.

## Avatars

- `GET /api/avatars/image/{urlencoded email}` → image bytes, or 404.
- `GET /api/avatars/url/{email}` → the resolved URL. Not needed: we fetch the image.

Both are `#[NoCSRFRequired]` and work with app-password auth
(`lib/Controller/AvatarsController.php`). Percent-encode the address — `+` is a real
character in a real address.

A 404 is normal and means "draw initials". Record it (`avatar.missing`) so the client does
not re-ask every launch. The 404 body is `text/html`, not JSON, so do not try to decode it.

## Capabilities (theming)

```http
GET {server}/ocs/v2.php/cloud/capabilities
```
→ `ocs.data.capabilities.theming.color` → `NCBrand(primaryHex:)` → `NCTheme(brand:)`.

The whole payload sits under an OCS envelope, `{"ocs": {"meta": {…}, "data": {…}}}`, so the
path has one more component than the line above used to show. `theming` also carries
`primaryColor`, `backgroundColor` and `cacheBuster`; `color` is the one to read.

Outside the Mail app's routes, so it takes the OCS prefix. Cache the colour in `meta`;
apply it at launch before the first frame to avoid a visible re-theme.

## Preferences worth reading

`GET /api/preferences/{key}`: `sort-order` (changes cursor semantics — see above),
`layout-message-view` (`threaded` or `singleton` default), `external-avatars`,
`auto-mark-as-read`. v1 reads them; it does not write them.

The response is `{"value": …}`, not the bare value, and `value` is **null** for any key the
user never set — which is all four of them on a fresh instance. Null means "the server
default", so `sort-order` unset is `newest`. Do not treat the null as a failure.

`GET /api/trustedsenders` is the other read v1 makes, and it answers with the
`JsonResponse::success` envelope, `{"status": "success", "data": [...]}`, rather than a bare
array. The element shape is unverified: the test server's list is empty.

## v2 Mail routes: what the live server answers (WS-16)

*Verified against Mail 5.12.0-rc.1 on Nextcloud 36, 2026-10-03. Every row has a recorded
fixture and a replay test in `NCMailNetTests/V2EndpointDecodingTests.swift`, except where
marked "source". The factories are in `NCMailNet/Endpoints/Endpoints+*.swift`.*

Where this table disagrees with `plan/API.md`, the table is what the server does.

| Route | Answer | Note |
| --- | --- | --- |
| `POST /api/accounts`, `PUT /api/accounts/{id}` | 201 / 200, **success envelope** around the account | source (`AccountsController::create`/`update`); not recorded — it needs a second real mailbox |
| `PATCH /api/accounts/{id}` | 200, the **bare** account | unlike create and update |
| `PUT /api/accounts/{id}/signature` | `[]` | |
| `PUT /api/accounts/{id}/smime-certificate` | `{"status":"success","data":null}` | |
| `GET /api/accounts/{id}/quota` | envelope, `{"usage","limit"}` | |
| `GET /api/accounts/{id}/test` | `{"data": true}` — **no `status` key** | the only envelope without one |
| `GET/POST/PUT/DELETE /api/accounts/{id}/aliases[/{id}]` | bare alias (array for GET); create is 201; DELETE echoes the deleted alias | a fresh alias has `signature` and `signatureMode` null |
| `GET /api/autoconfig/ispdb/{host}/{email}`, `/mx/{email}`, `/test` | envelope; ISPDB `{imapConfig, smtpConfig}`, MX `[host]`, test `true` | rate limited |
| `GET/POST/DELETE /api/delegations/{accountId}[/{userId}]` | bare `[{id, accountId, userId, displayName}]`; POST 201 with one; DELETE `[]` | self-delegation 400 `{"message": …}`, duplicate 409, provisioned 403 |
| `POST /api/oauth/state` | envelope `{"state": …}` | |
| `GET /ocs/v2.php/apps/mail/account/list` | OCS, `[{id, email, isDelegated, aliases: [{id, email, name}]}]` | the aliases are trimmed too: `email`, not `alias` |
| `POST /api/mailboxes` | the **bare** mailbox | `specialRole` is the integer 0 for a plain folder |
| `PATCH /api/mailboxes/{id}` | the **bare** updated mailbox | plan says nothing about the answer |
| `DELETE`, `POST …/clear`, `…/read`, `…/repair` on `/api/mailboxes/{id}` | `[]` | repair: 10 per 600 s |
| `GET /api/messages/{id}/source` | `{"source": "<RFC 822>"}` | |
| `GET /api/messages/{id}/itineraries` | bare array (KItinerary JSON-LD) | empty on the dev server |
| `GET /api/messages/{id}/dkim` | `{"valid": bool}` | |
| `GET /api/messages/{id}/export`, `/attachments` | bytes (`.eml`, `.zip`) | |
| `PUT`/`DELETE /api/messages/{id}/tags/{imapLabel}` | the **bare tag** | |
| `POST /api/messages/{id}/snooze`, `/unsnooze`, `/api/thread/{id}/snooze`, `/unsnooze` | `[]` | |
| `POST /api/messages/{id}/mdn` | **500** error envelope when the message asked for no receipt | not a 4xx |
| `POST /api/messages/{id}/attachment/{attachmentId}`, `/file` | `[]` | |
| `POST /api/list/unsubscribe/{id}` | **403** `{"status":"fail","data":null}` without a one-click header | |
| `GET /api/messages/{id}/smartreply`, `/api/thread/{id}/summary` | **204, empty body** with no LLM provider | `EmptyBodyRepresentable` |
| `GET /api/thread/{id}/eventdata` | `{"data": null}` when nothing is found | |
| `POST /api/drafts` | 201, envelope around the local message (`type` 1) | |
| `PUT /api/drafts/{id}`, `DELETE /api/drafts/{id}`, `POST /api/drafts/move/{id}` | **202** with the *success* envelope | see below |
| `GET /api/outbox` | envelope `{"messages": [...]}` — one level deeper than the draft answers | |
| `GET /api/outbox/{id}`, `POST /api/outbox`, `POST /api/outbox/from-draft/{id}` | envelope around the local message (`type` 0) | |
| `PUT /api/outbox/{id}`, `POST /api/outbox/{id}` (send), `DELETE /api/outbox/{id}` | **202** with the *success* envelope | |
| `POST /api/attachments` | 201, the bare local attachment, integer `id` | multipart field `attachment` |
| `POST /api/tags`, `PUT /api/tags/{id}` | the bare tag, server-derived `imapLabel` | |
| `DELETE /api/tags/{accountId}/delete/{id}` | `[id]` | |
| `GET /api/autoComplete?term=` | bare array; `id` is a **string or an integer** (collected addresses carry their row id) | |
| `GET /api/contactIntegration/autoComplete/{term}`, `/match/{mail}` | bare array, `email` is an **array** here | |
| `PUT /api/contactIntegration/add`, `/new` | the contact as Sabre JSON (`URI`, `UID`, `FN`, …) | |
| `PUT /api/preferences/{key}` | `{"value": …}`, like the GET | |
| `GET/PUT/DELETE /api/internalAddress[/{address}?type=]` | envelope; PUT echoes `{id, address, uid, type}` | |
| `PUT/DELETE /api/trustedsenders/{email}?type=domain` | `{"status":"success","data":null}` | |
| `GET /api/sieve/active/{id}`, `GET`/`POST /api/out-of-office/{id}[/follow-system]` | **400** `{"status":"fail","data":{"message":"ManageSieve is disabled"}}` with Sieve off | |
| `GET /api/sieve/active/{id}` (Sieve on) | **bare** `{"scriptName":null,"script":""}` — no envelope | `Endpoint<SieveScript>`; fixture `sieve-active-enabled.json` |
| `GET /api/out-of-office/{id}` (Sieve on) | envelope `{"state":null,"script":"","untouchedScript":""}` | `JSONEnvelope<OutOfOfficeFetch>`; `state` is the `OutOfOfficeState`, null until set |
| `PUT /api/sieve/account/{id}` | `{"sieveEnabled": …}` | |
| `GET`/`PUT /api/filter/{accountId}` | **500 with an HTML error page** with Sieve off | no message to show |
| `GET /api/filter/{accountId}` (Sieve on) | **bare** array, `[]` with no filters — no envelope | `Endpoint<[MailFilter]>`; fixture `filters-enabled.json` |
| `POST /api/follow-up/check-message-ids` | envelope `{"wasFollowedUp": [ids]}` | a read; retried |
| quick actions, action steps | envelope around the object; DELETE `data: null` | |
| `GET /api/textBlocks`, create, update, `…/{id}/shares` | envelope | |
| `GET /api/textBlockshares` | envelope around **text blocks** shared with the user | plan says "lists all shares"; it lists blocks |
| `POST`/`DELETE /api/textBlockshares` | `{"status":"success","data":null}` | |
| `GET/POST/DELETE /api/smime/certificates` | envelope; the parsed metadata sits in a nested `info` | import is multipart |

**202 is not always "sync in progress".** v1 read every 202 as `IncompleteSyncException`.
Drafts and outbox answer 202 to update, delete, move and send, with the success envelope.
`MailClient` now treats a 202 as success when the body's `status` is `success` and as
`syncInProgress` otherwise (ADR-0077).

## Drafts, the outbox and what a send does on the server (WS-23)

*Verified by `OutboxLiveTests` on 2026-10-04 (every send to the account's own address,
ADR-0080) and read from the nextcloud/mail source where noted.*

- **`draftId` is an IMAP message id, not a `/api/drafts` id.** On `POST /api/drafts` and
  `POST /api/outbox` it names a mirrored message in the Drafts folder, which
  `DeleteDraftListener` flags `\Deleted` and expunges. Verified: a draft closed to IMAP,
  then a new draft sent with `draftId` = that message's id — the Drafts copy was gone
  within the next cache sync (`sendingADraftFromTheDraftsFolderExpungesIt`).
- **The server moves idle drafts by itself.** Its job (`DraftsService::flush`, source)
  moves every `/api/drafts` row untouched for 300 s *with `sendAt` NULL* to the IMAP Drafts
  folder and deletes the row. Afterwards `PUT /api/drafts/{id}` answers **404**
  `{"status":"fail","data":[]}` (verified with a missing id).
- **`POST /api/drafts/move/{id}`** does the same move now (202, success envelope); the
  server row is deleted, so the id is dead afterwards.
- **`POST /api/outbox/from-draft/{id}` keeps the id.** The draft becomes an outbox message
  (`type` 0) with the same `id`. The routes are typed: `PUT /api/drafts/{id}` 404s on an
  outbox message, `GET /api/outbox/{id}` 404s on a draft, and both 404 once sent.
- **Draft cleanup on send:** after `from-draft` + `POST /api/outbox/{id}` the server draft
  is gone (`PUT /api/drafts/{id}` → 404) and `GET /api/outbox` is empty — the send chain
  deletes the row and its local attachments when it reaches `STATUS_PROCESSED`. There is no
  second object to clean up. A draft that had been moved to IMAP is only removed if its
  message id is passed as `draftId` (above).
- **`POST /api/outbox/{id}` failure** is HTTP 500 with
  `{"status":"error", …, "data":[<the message>]}` (source); the row stays in the outbox
  with its `status`. Status 11 (`STATUS_IMAP_SENT_MAILBOX_FAIL`) means SMTP succeeded and
  only the Sent copy failed; the web client's "Copy to Sent" is the same
  `POST /api/outbox/{id}`, and the chain resumes at the copy step.
- **Recently contacted:** each send made from a user request dispatches
  `ContactInteractedWithEvent` for every recipient, and the `contactsinteraction` app
  updates its address book `z-app-generated--contactsinteraction--recent`. Verified: the
  card for the account's own address there changed ETag and `Last-Modified` to the second of
  each live send (09:46:09 and 09:47:09 UTC). The listener needs a user session (source), so
  a scheduled message sent by the server's background job does **not** record an
  interaction. `GET /api/autoComplete?term=` (Basic auth) stayed `[]` for the address
  afterwards; the address collector's table was not inspected.
- **Timing (live, nextcloud.local):** `send()` to dispatch complete 13.5 s, of which 10 s is
  the undo window and ~3.5 s the three requests (`PUT` draft, `from-draft`, send); the
  message was in the Sent cache 9.8 s later.

## Non-Mail OCS routes

*The five integrations the brief listed as unverified, each confirmed with curl against the
live server (Basic auth, `OCS-APIRequest: true`, `Accept: application/json`). All take the
OCS envelope `{"ocs": {"meta": {status, statuscode, message}, "data": …}}`.*

### Translation

- `GET /ocs/v2.php/translation/languages` → 200,
  `{"languages": [], "languageDetection": false}` on a server with no provider. The route
  exists either way; an empty list is the "translation unavailable" signal.
- `POST /ocs/v2.php/translation/translate`, body `{"text", "fromLanguage": null,
  "toLanguage"}` → with no provider, **HTTP 412**, OCS 412,
  `data.message: "No translation provider available"`.
- TaskProcessing is offered too: `GET /ocs/v2.php/taskprocessing/tasktypes` → 200,
  `{"types": []}` (PHP's empty map; an object keyed by task type id when a provider
  exists). Mail's own `llm_translation_enabled` checks `core:text2text:translate` there.
  The client calls the dedicated translation API for translating and reads TaskProcessing
  for flags only ([server-flags.md](server-flags.md)).

### Smart Picker

- `GET /ocs/v2.php/references/providers` → 200, array of
  `{id, title, icon_url, order, search_providers_ids?}`. `search_providers_ids` is absent
  for providers that are not search-backed (calendar, polls).
- `GET /ocs/v2.php/search/providers/{providerId}/search?term=&limit=&cursor=` → 200,
  `{name, isPaginated, cursor, entries: [{thumbnailUrl, title, subline, resourceUrl, icon,
  rounded, attributes}]}`. `cursor` is echoed back verbatim for the next page (an integer
  for `files`).
- `core.reference-api: true` in capabilities says the reference API exists.

### Notifications

- `GET /ocs/v2.php/apps/notifications/api/v2/notifications` and
  `DELETE …/notifications/{id}` → **HTTP 404**, OCS 998 "Invalid query", `data: []` on the
  live server, because the notifications app is not installed (no `notifications`
  capability). That 404 is the "no notifications surface" signal, not an error to show.
  The success shape is not verifiable here; the model's fields are optional.

### Files sharing — public links

- `POST /ocs/v2.php/apps/files_sharing/api/v1/shares`, body `{"path": "/file", "shareType":
  3}` → 200, the share: `id` is a **string**, `share_type` 3, `token`, `url` (the public
  link), plus ~35 more keys. Verified by creating and deleting a link.
- `DELETE /ocs/v2.php/apps/files_sharing/api/v1/shares/{id}` → 200, `data: []`.

### Circles / Teams

- `GET /ocs/v2.php/apps/circles/circles` → 200, array of
  `{id, name, displayName, sanitizedName, source, population, populationInherited, config,
  description, url, creation, initiator, owner, settings, invitationCode}`. `id` is the
  circle's string id. `initiator` is the asking user's own membership (`level`, `singleId`);
  the list holds only teams the user belongs to (alice saw none of admin's).
- Confirmed live by WS-37 (Nextcloud 36; fixtures `circle-*-ws37.json`), each answering the
  OCS wrapper with the changed circle or member under `data` (`[]` for a member removal):
  - `POST …/circles` `{name, personal, local}` → the new circle (`creation` 0 until listed).
  - `PUT …/circles/{id}/name|description|config` `{value}`; `config` is the whole bit field
    (8 visible, 16 open, 32 invite, 64 request, 128 friend, 8192 root, 32768 federated).
  - `DELETE …/circles/{id}`; `PUT …/circles/{id}/leave` (refused for the owner).
  - `GET …/circles/{id}/members` → `[{id, singleId, userId, userType, level, status,
    displayName, basedOn: {source, …}, …}]`. A **group** member comes back with `userType`
    16 and `basedOn.source` 2; an address with `userType` 4 and `userId` = the address.
  - `POST …/circles/{id}/members` `{userId, type}` (1 user, 2 group, 4 email, 8 contact,
    16 team — the team's id).
  - `PUT …/circles/{id}/members/{memberId}/level` `{level}` — **`level`**, not `value`
    (1 member, 4 moderator, 8 admin, 9 owner).
  - `PUT …/circles/{id}/members/{memberId}` (no body) accepts a join request (a member at
    level 0, status `Requesting`); `DELETE` the same path removes or rejects.
- Circles is present when `GET /ocs/v2.php/cloud/capabilities` lists `circles` (with
  `settings.frontendEnabled`, `allowedCircles` …). That is how the client gates Teams
  (ADR-0097).

### Files shares (Shared items, WS-37)

- `GET /ocs/v2.php/apps/files_sharing/api/v1/shares` → the login's shares;
  `?shared_with_me=true` → shares it received. Each `{id: "18" (string), share_type (0 user),
  uid_owner, share_with, path, file_target, item_type, mimetype, file_source, stime, …}`.
  Fixtures `shares-mine-ws37.json`, `shares-with-me-ws37.json`.

## Contacts app extras: favourites and social avatars (WS-35)

*Measured against the dev server on 2026-10-04 with the scratch book `ws35-temp-fav`
(`Scripts/record-fixtures.sh`, "DAV: WS-35 favourites and social avatar"), and again by
`ContactsLiveTests` through the queue.*

### The favourite star is a DAV property, not vCard

- Web Contacts' star is the dead property **`{http://nextcloud.com/ns}favorite`** on the card
  resource — the `.com` namespace, unlike every other Nextcloud DAV property (`.org`). It is
  not in the vCard at all.
- Set: `PROPPATCH <card>` with `<d:set><d:prop><nc:favorite>1</nc:favorite>…` → 207, the
  property echoed in a 200 propstat (`dav-ws35-favorite-proppatch.xml`). Unset:
  `<d:remove><d:prop><nc:favorite/>…` → 207 with a **204** propstat
  (`dav-ws35-favorite-unproppatch.xml`).
- Read: a Depth-1 `PROPFIND {getetag, nc:favorite}` on the book answers `1` for a starred card
  and a **404 propstat** for every other (`dav-ws35-favorites.xml`); `addressbook-multiget`
  answers it beside `address-data` the same way (`dav-ws35-multiget-favorite.xml`).
- The PROPPATCH moves **neither the card's ETag nor the book's sync-token** (live:
  `favouriteRoundTripsBothWays` — "sync-token moved false, ETag moved false"), so
  `sync-collection` never reports a toggle. The mirror lists favourites each pass
  ([ADR-0092](../decisions/0092-contact-favourites-are-a-dav-dead-property-refreshed-each-pass.md)).

### Social avatar

- `PUT /index.php/apps/contacts/api/v1/social/avatar/{network}/{addressBookURI}/{UID}` with
  Basic auth and `OCS-APIRequest: true` (which passes the CSRF check) → **200 `[]`**
  (`contacts-social-avatar.json`). The route was "unverified" in the plan; this settles it.
  `{addressBookURI}` is the book's last path segment (`contacts`), `{UID}` the vCard `UID`.
- The server downloads the picture itself and rewrites the card's `PHOTO`; the change moves
  the ETag and the token like any edit, so the next pass brings it in (live: "PHOTO present
  after next pass: true" for `gravatar`). The web client treats 304 as "Avatar already up to
  date".
- Networks: the Contacts page's `supportedNetworks` initial state on this server is
  `["instagram","mastodon","tumblr","diaspora","xing","telegram","gravatar"]`; web Contacts
  offers those the card has an `X-SOCIALPROFILE`/`IMPP` of that type for, plus `gravatar`
  when it has an `EMAIL`. There is no API for the list, so the app carries it.
