<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# API payloads and semantics

*The exact shapes this app decodes, and the endpoint behaviour that is not obvious from the
shapes. Every claim cites `nextcloud/mail` at app version 5.12.0-rc.1.*

The complete endpoint map — including everything v1 does not use — is
[../../plan/API.md](../../plan/API.md). This document covers only what v1 touches, plus the
traps.

## Read this first: the four traps

Each has already been designed around. They are collected here because each one costs a day
if it is met in a debugger instead of a document.

**1. `view=threaded` returns one message per thread.** Not a display hint — the query joins
the message table to itself on `thread_root_id` and keeps rows with no newer sibling
(`lib/Db/MessageMapper.php::findIdsByQuery`). Enumerate with `view=singleton` or silently
lose every reply. [ADR-0014](../decisions/0014-singleton-enumeration.md)

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

And one more, cheaper but sharp: **`mailbox.id` is not an id.** It is
`base64_encode(name)`. The numeric key every other endpoint wants is `databaseId`.

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
  "signature": null, "signatureMode": null, "signatureAboveQuote": false,
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
  "path": null
}
```

v1 needs: `id`, `name`, `emailAddress`, `order`, and the six special mailbox ids. The rest
is stored in `account.rawJSON` against future use.

Special mailbox ids may be `null` on a freshly provisioned account. Triage actions that
depend on one (archive, junk) must be disabled rather than crash — and that state is worth
a decent empty-state message, not a greyed button with no explanation.

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
  "myAcls": null,
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
  it leniently.

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
  "tags": { "$label1": { "id": 1, "displayName": "Important", "color": "#ff0000", … } },
  "from": [{ "label": "Sookie St. James", "email": "sookie@dragonfly.example" }],
  "to": [...], "cc": [...], "bcc": [...],
  "mailboxId": 42,
  "messageId": "<abc@dragonfly.example>",
  "inReplyTo": null,
  "references": null,                 // null or an array
  "threadRootId": "…",
  "imipMessage": false,
  "previewText": "I moved the risotto…",
  "summary": null,
  "encrypted": false,
  "mentionsMe": false,
  "avatar": { "isExternal": false, "mime": "image/jpeg", "url": "…" },   // or null
  "fetchAvatarFromClient": false,
  "attachments": []
}
```

- **`flags` keys include `$junk`, `$notjunk`, `$mdnsent`** — leading `$`, so
  `CodingKeys` must spell them explicitly.
- **`tags` is a dictionary keyed by IMAP label**, not an array.
- **`dateInt` is the cursor** for `GET /api/messages`: pass the oldest one you have seen.
- **`references` is `null` or an array**, never a string.

## Message body

`GET /api/messages/{id}/body`. Source: `MessagesController::getBody` +
`lib/Model/IMAPMessage.php::getFullMessage`.

```jsonc
{
  "uid": 4711, "messageId": "<…>", "subject": "…", "dateInt": 1737100000,
  "from": [...], "to": [...], "cc": [...], "bcc": [...], "replyTo": [...],
  "flags": [...],                     // NOTE: an ARRAY here, an object on the envelope
  "hasHtmlBody": true,
  "body": "<div>…</div>",             // sanitised HTML, or plain text when hasHtmlBody is false
  "signature": "…",                   // plain-text messages only
  "attachments": [...], "inlineAttachments": [...],
  "dispositionNotificationTo": null,
  "hasDkimSignature": true, "dkimValid": true,
  "phishingDetails": {...},
  "unsubscribeUrl": null, "unsubscribeMailto": null, "isOneClickUnsubscribe": false,
  "scheduling": [...],
  "isPgpMimeEncrypted": false,
  "hasAiGeneratedHeader": false,
  "itineraries": [...],               // only when cached
  "accountId": 3, "mailboxId": 42, "databaseId": 90210,
  "isSenderTrusted": false,
  "smime": { "isEncrypted": false, "isSigned": false, "signatureIsValid": null }
}
```

**`flags` is an array here and an object on the envelope.** Two types, one name. Decode
them separately and do not share a model.

Attachment entries (`enrichAttachment`):

```jsonc
{ "id": "2", "messageId": 90210, "fileName": "menu.pdf", "mime": "application/pdf",
  "size": 183422, "cid": null, "disposition": "attachment",
  "downloadUrl": "https://…", "mimeUrl": "…", "isImage": false, "isCalendarEvent": false }
```

`id` is a **string** (`"2"`, `"2.1"`), not a number.

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

`lastMessageTimestamp` only affects the oldest-first sort order
(`MessageMapper::findNewIds`). With `sortOrder: "newest"` it is ignored; send it anyway for
forward compatibility.

## Messages list

```http
GET /api/messages?mailboxId=42&view=singleton&limit=100&cursor=1737000000
```

- `limit` clamped server-side to 1…100 (`MessagesController::index`).
- `cursor` = `dateInt` of the oldest envelope received so far.
- `view`: `singleton` or `threaded` — trap 1.
- `filter` takes the search filter string (`plan/API.md`); v1 searches locally and does not
  use it, except in the one place noted in [../architecture/sync-engine.md](../architecture/sync-engine.md).
- Sort order comes from the user's server-side `sort-order` preference, **not** a
  parameter. A user who set "oldest first" in the web client changes what `cursor` means.
  Read `GET /api/preferences/sort-order` at startup and pass the matching `sortOrder` to
  sync.
- An uncached mailbox throws `MailboxNotCachedException` → **400** with a
  `{"status":"error"}` body. Prime with `init: true` first.

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

## Avatars

- `GET /api/avatars/image/{urlencoded email}` → image bytes, or 404.
- `GET /api/avatars/url/{email}` → the resolved URL. Not needed: we fetch the image.

Both are `#[NoCSRFRequired]` and work with app-password auth
(`lib/Controller/AvatarsController.php`). Percent-encode the address — `+` is a real
character in a real address.

A 404 is normal and means "draw initials". Record it (`avatar.missing`) so the client does
not re-ask every launch.

## Capabilities (theming)

```http
GET {server}/ocs/v2.php/cloud/capabilities
```
→ `data.capabilities.theming.color` → `NCBrand(primaryHex:)` → `NCTheme(brand:)`.

Outside the Mail app's routes, so it takes the OCS prefix. Cache the colour in `meta`;
apply it at launch before the first frame to avoid a visible re-theme.

## Preferences worth reading

`GET /api/preferences/{key}`: `sort-order` (changes cursor semantics — see above),
`layout-message-view` (`threaded` or `singleton` default), `external-avatars`,
`auto-mark-as-read`. v1 reads them; it does not write them.
