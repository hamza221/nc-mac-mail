# Nextcloud Mail API map

> **Status: current reference, still accurate.** This is the complete endpoint map and
> remains the first place to look for anything the app does not use yet.
>
> For the subset v1 actually calls, the exact JSON shapes, and the four endpoint traps that
> cost a day each if met in a debugger, see
> [docs/reference/api-payloads.md](../docs/reference/api-payloads.md).

Every endpoint in `appinfo/routes.php` plus the ones declared with route attributes,
with the parameters each controller method accepts.
Source: https://github.com/nextcloud/mail (main, app version 5.12.0-rc.1).

## Conventions

- App routes live under `/index.php/apps/mail/`. Paths below are written relative to that prefix.
- OCS routes live under `/ocs/v2.php/apps/mail/` and are called out where they apply.
- Everything needs an authenticated session. Most endpoints carry `#[NoAdminRequired]`; the `settings#*` endpoints are the exception and require an admin.
- Non-OCS endpoints need the `requesttoken` CSRF header, except the few marked `#[NoCSRFRequired]`.
- `#[TrapError]` on a method means exceptions are converted into a JSON error response instead of a stack trace.
- Parameters are read from the query string for GET and DELETE, and from the JSON body for POST, PUT and PATCH, unless the entry says otherwise.
- Access to another user's account goes through `DelegationService`, which resolves the effective user for every account, mailbox, message, alias and draft id. A user without a delegation gets 403.
- `resources` entries in `routes.php` expand to the usual five routes: `GET /x` (index), `POST /x` (create), `GET /x/{id}` (show), `PUT /x/{id}` (update), `DELETE /x/{id}` (destroy). Where a controller does not implement one, it is left out below.

## Pages (HTML, not JSON)

These render the Vue app and are listed for completeness.

- `GET /` opens the app.
- `GET /setup` opens the account setup screen.
- `GET /box/{id}` opens a mailbox.
- `GET /box/starred/{id}` opens a mailbox filtered to starred messages.
- `GET /box/{mailboxId}/thread/{id}` opens a thread.
- `GET /box/{filter}/{mailboxId}/thread/{id}` opens a thread inside a filtered list.
- `GET /box/{mailboxId}/thread/new/{draftId}` opens a draft.
- `GET /box/{filter}/{mailboxId}/thread/new/{draftId}` opens a draft inside a filtered list.
- `GET /outbox` and `GET /outbox/{messageId}` open the outbox.
- `GET /compose?uri=...` opens the composer prefilled from a `mailto:` URI.
- `GET /mailto` is the registered `mailto:` protocol handler target.
- `GET /open/{messageId}` resolves an RFC 2392 Message-ID across the user's accounts and redirects to the thread. `#[NoCSRFRequired]`. Redirects to login when logged out, and to the app root when the id cannot be resolved.

## Accounts

- `GET /api/accounts` lists the user's accounts. No parameters.
- `GET /api/accounts/{id}` returns one account.
- `POST /api/accounts` creates an account.
  Params: `accountName`, `emailAddress`, `imapHost`, `imapPort`, `imapSslMode`, `imapUser`, `smtpHost`, `smtpPort`, `smtpSslMode`, `smtpUser`, optional `imapPassword`, `smtpPassword`, `authMethod` (default `password`), `classificationEnabled`.
- `PUT /api/accounts/{id}` replaces the server settings. Same parameters as create, minus `classificationEnabled`.
- `PATCH /api/accounts/{id}` updates individual account settings. Every parameter is optional and only the ones sent are changed.
  Params: `editorMode`, `order`, `showSubscribedOnly`, `draftsMailboxId`, `sentMailboxId`, `trashMailboxId`, `archiveMailboxId`, `snoozeMailboxId`, `signatureAboveQuote`, `trashRetentionDays`, `junkMailboxId`, `searchBody`, `classificationEnabled`, `imipCreate`.
- `DELETE /api/accounts/{id}` deletes the account and its cached data.
- `PUT /api/accounts/{id}/signature` sets the account signature. Params: `signature` (nullable, clears it when null).
- `PUT /api/accounts/{id}/smime-certificate` links an S/MIME certificate to the account. Params: `smimeCertificateId` (nullable to unlink).
- `GET /api/accounts/{id}/quota` returns the IMAP quota for the account.
- `GET /api/accounts/{id}/test` runs a live IMAP and SMTP connection test.
- `POST /api/accounts/{id}/draft` writes a draft straight to the IMAP drafts folder.
  Params: `subject`, `body`, `to`, `cc`, `bcc`, `isHtml` (default true), `draftId`.

### Account OCS endpoint

- `GET /ocs/v2.php/apps/mail/account/list` returns the user's accounts including delegated ones, for other apps. `#[NoCSRFRequired]`.

## Aliases

- `GET /api/accounts/{accountId}/aliases` lists the aliases of an account.
- `POST /api/accounts/{accountId}/aliases` creates one. Params: `alias` (the address), `aliasName` (display name).
- `PUT /api/accounts/{accountId}/aliases/{id}` updates one. Params: `alias`, `aliasName`, optional `smimeCertificateId`.
- `DELETE /api/accounts/{accountId}/aliases/{id}` removes one.
- `PUT /api/accounts/{accountId}/aliases/{id}/signature` sets the alias signature. Params: `signature` (nullable).

## Auto configuration

All three are rate limited per user.

- `GET /api/autoconfig/ispdb/{host}/{email}` queries the Mozilla ISPDB for a server configuration. Limit: 5 per 60 s.
- `GET /api/autoconfig/mx/{email}` resolves the MX records for the address domain and derives a configuration guess. Limit: 5 per 60 s.
- `GET /api/autoconfig/test?host=&port=` checks whether a host and port accept a connection. Limit: 30 per 60 s.

## Mailboxes

- `GET /api/mailboxes?accountId=&forceSync=` lists the folders of an account. `forceSync` defaults to false and triggers a folder list refresh from IMAP.
- `POST /api/mailboxes` creates a folder. Params: `accountId`, `name` (use the server's delimiter for subfolders).
- `PATCH /api/mailboxes/{id}` updates folder properties. Optional params: `name` (renames or moves), `subscribed`, `syncInBackground`.
- `DELETE /api/mailboxes/{id}` deletes the folder and everything in it.
- `POST /api/mailboxes/{id}/sync` synchronises the folder and returns new, changed and vanished messages.
  Params: `ids` (known message ids, default `[]`), `lastMessageTimestamp`, `init` (default false, forces a full initial sync), `sortOrder` (`newest` or `oldest`), `query` (search filter string).
- `DELETE /api/mailboxes/{id}/sync` drops the local cache for the folder so the next sync starts over.
- `POST /api/mailboxes/{id}/clear` deletes every message in the folder.
- `POST /api/mailboxes/{id}/read` marks every message in the folder as read.
- `GET /api/mailboxes/{id}/stats` returns total and unread counts.
- `POST /api/mailboxes/{id}/repair` rebuilds the local state for the folder. Limit: 10 per 600 s.

### Mailbox OCS endpoints

- `GET /ocs/v2.php/apps/mail/ocs/mailboxes?accountId=` lists folders. `#[NoCSRFRequired]`.
- `GET /ocs/v2.php/apps/mail/ocs/mailboxes/{mailboxId}/messages` lists messages.
  Params: `cursor`, `filter` (search filter string), `limit` (omit for all), `view` (`singleton` or `threaded`).

## Messages

- `GET /api/messages?mailboxId=&cursor=&filter=&limit=&view=&v=` lists messages in a folder.
  `limit` is clamped to 1..100. `view` is `singleton` or `threaded`. `filter` takes the search filter string (see below). Sort order comes from the user's `sort-order` preference. Passing any non-empty `v` turns on HTTP caching for 7 days, so it is used as a cache buster.
- `GET /api/messages/{id}` returns the message envelope and metadata.
- `DELETE /api/messages/{id}` moves the message to trash, or deletes it when it is already there.
- `GET /api/messages/{id}/body` returns the parsed body and attachment list.
- `GET /api/messages/{id}/html?plain=` returns the sanitised HTML body for the iframe. `plain` (default false) strips the styling.
- `GET /api/messages/{id}/source` returns the raw RFC 822 source.
- `GET /api/messages/{id}/export` downloads the message as an `.eml` file.
- `GET /api/messages/{id}/thread` returns the other messages in the same thread.
- `GET /api/messages/{id}/itineraries` returns the KItinerary extraction result (flights, trains, event bookings).
- `GET /api/messages/{id}/dkim` returns the DKIM verification result.
- `PUT /api/messages/{id}/flags` sets IMAP flags. Params: `flags`, a map such as `{"seen": true, "flagged": false}`. Recognised keys cover seen, flagged, answered, deleted, draft, forwarded, junk, notjunk, mdnsent and the app's own important flag.
- `PUT /api/messages/{id}/tags/{imapLabel}` adds a tag.
- `DELETE /api/messages/{id}/tags/{imapLabel}` removes a tag.
- `POST /api/messages/{id}/move` moves the message. Params: `destFolderId`.
- `POST /api/messages/{id}/snooze` hides the message until a time. Params: `unixTimestamp`, `destMailboxId` (the snooze folder).
- `POST /api/messages/{id}/unsnooze` brings it back immediately.
- `POST /api/messages/{id}/mdn` sends a read receipt for a message that requested one.
- `GET /api/messages/{id}/attachment/{attachmentId}` downloads one attachment.
- `POST /api/messages/{id}/attachment/{attachmentId}` saves that attachment into Files. Params: `targetPath`.
- `GET /api/messages/{id}/attachments` downloads every attachment as a zip.
- `POST /api/messages/{id}/file` saves the whole message into Files as `.eml`. Params: `targetPath`.
- `GET /api/messages/{messageId}/smartreply` returns two LLM-generated reply suggestions. Needs LLM processing enabled by the admin.

### Message OCS endpoints

Intended for other apps and integrations.

- `GET /ocs/v2.php/apps/mail/message/{id}` returns the message. Brute-force protected under `mailGetMessage`, `#[NoCSRFRequired]`. Returns 206 when the body could only be fetched partially.
- `GET /ocs/v2.php/apps/mail/message/{id}/raw` returns the raw source. Brute-force protected under `mailGetRawMessage`.
- `GET /ocs/v2.php/apps/mail/message/{id}/attachment/{attachmentId}` returns one attachment.
- `POST /ocs/v2.php/apps/mail/message/send` sends a message directly over SMTP. Limit: 5 per 100 s.
  Params: `accountId`, `fromEmail` (account address or one of its aliases), `subject`, `body`, `isHtml`, `to` (list of `{email, label?}`), optional `cc`, `bcc`, `references` (an RFC 2392 Message-ID used to set Reply-To and References).

## Threads

- `POST /api/thread/{id}` moves a whole thread. Params: `destMailboxId`.
- `DELETE /api/thread/{id}` deletes a whole thread.
- `POST /api/thread/{id}/snooze` snoozes the thread. Params: `unixTimestamp`, `destMailboxId`.
- `POST /api/thread/{id}/unsnooze` unsnoozes it.
- `GET /api/thread/{id}/summary` returns an LLM summary of the thread.
- `GET /api/thread/{id}/eventdata` returns a suggested calendar event title and agenda derived from the thread.

`{id}` here is the id of any message in the thread; the thread root is resolved server side.

## Drafts

Drafts are stored locally first and flushed to IMAP by a background job.

- `POST /api/drafts` creates a local draft.
  Params: `accountId`, `subject`, `bodyPlain`, `bodyHtml`, `editorBody`, `isHtml`, `smimeSign`, `smimeEncrypt`, `to`, `cc`, `bcc` (each a list of recipients, default `[]`), `attachments` (default `[]`), `aliasId`, `inReplyToMessageId`, `smimeCertificateId`, `sendAt`, `draftId`, `requestMdn` (default false), `isPgpMime` (default false), `isAiGenerated` (default false).
- `PUT /api/drafts/{id}` updates a draft. Same parameters plus `failed` (default false), without `draftId`.
- `DELETE /api/drafts/{id}` discards a draft.
- `POST /api/drafts/move/{id}` writes the local draft to the IMAP drafts folder now.

## Outbox

- `GET /api/outbox` lists queued messages.
- `GET /api/outbox/{id}` returns one.
- `POST /api/outbox` queues a message.
  Params: identical to the draft create call, with `draftId` to consume an existing draft and `sendAt` for scheduled sending.
- `PUT /api/outbox/{id}` updates a queued message. Same parameters, without `draftId`.
- `DELETE /api/outbox/{id}` removes it from the queue.
- `POST /api/outbox/{id}` sends it immediately.
- `POST /api/outbox/from-draft/{id}` turns a draft into a scheduled outbox message. Params: `sendAt`.

Scheduled sending is hidden in the UI when the server runs ajax cron, since the worker job would not run reliably.

## Attachments (upload)

- `POST /api/attachments` uploads a file for use as an attachment. The file goes in the multipart field `attachment`. Optional `accountId` stores the upload under the account owner so it works when composing for a delegated account. Returns the local attachment record with `201`.

## Tags

- `POST /api/tags` creates a tag. Params: `displayName`, `color`.
- `PUT /api/tags/{id}` renames or recolours it. Params: `displayName`, `color`.
- `DELETE /api/tags/{accountId}/delete/{id}` deletes the tag from one account.

## Search and autocomplete

- `GET /api/autoComplete?term=` returns matching recipients from Nextcloud contacts, collected addresses, users and groups.
- `GET /api/contactIntegration/autoComplete/{term}` returns matching contacts from the Contacts app.
- `GET /api/contactIntegration/match/{mail}` looks up the contact behind an address.
- `PUT /api/contactIntegration/add` adds an address to an existing contact. Params: `uid`, `mail`.
- `PUT /api/contactIntegration/new` creates a contact. Params: `contactName`, `mail`.

### Search filter string

The `filter` parameter on the message list endpoints is parsed by `FilterStringParser`. Tokens are separated by spaces and values are URL-encoded.

`from:`, `to:`, `cc:`, `bcc:`, `subject:`, `body:` match those fields.
`tags:a,b` matches any of the listed tags.
`start:` and `end:` bound the date range.
`match:` sets the match mode.
`mentions:true` limits to messages that mention the user.
`flags:` takes a comma-separated list of `answered`, `read`, `unread`, `starred`, `important`, `attachments`.
`is:x` and `not:x` take the same flag names plus `pi-important` and `pi-other`, which are the two priority inbox sections.

## Avatars and image proxy

- `GET /api/avatars/url/{email}` returns the avatar URL for an address, resolved from the address book, Gravatar, or the sender domain's favicon.
- `GET /api/avatars/image/{email}` returns the avatar image itself.
- `GET /proxy?src=&id=&hmac=` fetches a remote image referenced by a message so the user's IP is not exposed. Requires the message `id` and an `hmac` generated server side for that `src`; a mismatch returns 401. Falls back to a placeholder image when the remote fetch fails or the target is a local address. Limit: 50 per 60 s.

## Preferences (per user)

- `GET /api/preferences/{key}` reads one preference.
- `PUT /api/preferences/{key}` writes one. Body: `key`, `value`.

Known keys: `account-settings`, `sort-order`, `external-avatars`, `layout-mode`, `layout-message-view`, `reply-mode`, `collect-data`, `search-priority-body`, `start-mailbox-id`, `follow-up-reminders`, `sort-favorites`, `index-context-chat`, `compact-mode`, `auto-mark-as-read`, `internal-addresses`, `smime-sign-aliases`.

## Trusted senders and internal addresses

- `GET /api/trustedsenders` lists the trusted senders.
- `PUT /api/trustedsenders/{email}?type=` trusts a sender so its remote images load. `type` is `individual` or `domain`.
- `DELETE /api/trustedsenders/{email}?type=` removes the trust.
- `GET /api/internalAddress` lists internal addresses and domains.
- `PUT /api/internalAddress/{address}?type=` marks an address or domain as internal, so it is not flagged as an external sender. `type` is `individual` or `domain`.
- `DELETE /api/internalAddress/{address}?type=` removes it.

## Sieve and mail filters

- `PUT /api/sieve/account/{id}` configures the Sieve connection.
  Params: `sieveEnabled`, `sieveHost`, `sievePort`, `sieveUser`, `sievePassword`, `sieveSslMode`.
- `GET /api/sieve/active/{id}` returns the active Sieve script.
- `PUT /api/sieve/active/{id}` replaces it. Params: `script`.
- `GET /api/filter/{accountId}` returns the filters parsed out of the managed section of the Sieve script.
- `PUT /api/filter/{accountId}` replaces them and regenerates the script. Params: `filters`, a list of objects with `name`, `enable`, `operator` (`allof` or `anyof`), `priority`, `tests` (each `{field, operator, values}` where field is `from`, `subject` or `to` and operator is `contains`, `is` or `matches`), and `actions` (each a `{type, ...}` object of type `addflag`, `addsystemflag`, `fileinto`, `redirect` or `stop`).

## Out of office

- `GET /api/out-of-office/{accountId}` returns the current autoresponder state parsed from the Sieve script.
- `POST /api/out-of-office/{accountId}` updates it. Params: `enabled`, `start`, `end` (nullable ISO dates), `subject`, `message`.
- `POST /api/out-of-office/{accountId}/follow-system` makes the account follow the Nextcloud absence setting instead.

## Follow-up reminders

- `POST /api/follow-up/check-message-ids` takes `messageIds` (a list of local message ids) and returns the subset that already received a reply, so the client can drop them from the follow-up list.

## Quick actions

- `GET /api/quick-actions` lists the user's action chains.
- `POST /api/quick-actions` creates one. Params: `name`, `accountId`.
- `PUT /api/quick-actions/{id}` renames one. Params: `name`.
- `DELETE /api/quick-actions/{id}` deletes one.
- `POST /api/action-step` adds a step. Params: `name` (one of `markAsSpam`, `applyTag`, `snooze`, `moveThread`, `deleteThread`, `markAsRead`, `markAsUnread`, `markAsImportant`, `markAsFavorite`), `order`, `actionId`, plus `tagId` for `applyTag` and `mailboxId` for `moveThread`.
- `PUT /api/action-step/{id}` updates a step. Params: `name`, `order`, `tagId`, `mailboxId`.
- `DELETE /api/action-step/{id}` removes a step.

## Text blocks

- `GET /api/textBlocks` lists the user's text blocks and the ones shared with them.
- `POST /api/textBlocks` creates one. Params: `title`, `content`.
- `PUT /api/textBlocks/{id}` updates one. Params: `title`, `content`.
- `DELETE /api/textBlocks/{id}` deletes one.
- `GET /api/textBlocks/{id}/shares` lists the shares of one text block.
- `GET /api/textBlockshares` lists all shares. Note the lowercase `s` in the resource path; it does not match the `/api/textBlocks` spelling.
- `POST /api/textBlockshares` shares a text block. Params: `textBlockId`, `shareWith` (user or group id), `type` (`user` or `group`).
- `DELETE /api/textBlockshares/{id}?shareWith=` removes a share.

## S/MIME certificates

- `GET /api/smime/certificates` lists the user's certificates with parsed subject, issuer, purposes and expiry.
- `POST /api/smime/certificates` uploads one. Multipart fields: `certificate` (required) and `privateKey` (optional). PKCS#12 is converted in the browser first, since the server cannot decrypt it.
- `DELETE /api/smime/certificates/{id}` deletes one.

## Delegation

- `GET /api/delegations/{accountId}` lists the users the account is delegated to.
- `POST /api/delegations/{accountId}` grants access. Params: `userId`.
- `DELETE /api/delegations/{accountId}/{userId}` revokes it.

## Mailing list

- `POST /api/list/unsubscribe/{id}` acts on the `List-Unsubscribe` header of a message, sending the unsubscribe mail or following the one-click URL.

## OAuth integrations

- `POST /api/oauth/state` mints a signed state token for an OAuth flow. Params: `accountId`.
- `POST /api/integration/google` stores the Google OAuth client. Admin only. Params: `clientId`, `clientSecret`.
- `DELETE /api/integration/google` removes it.
- `GET /integration/google-auth` is the OAuth redirect target. Query: `code`, `state`, `scope`, `error`.
- `POST /api/integration/microsoft` stores the Microsoft OAuth client. Admin only. Params: `tenantId` (nullable, defaults to `common`), `clientId`, `clientSecret`.
- `DELETE /api/integration/microsoft` removes it.
- `GET /integration/microsoft-auth` is the OAuth redirect target. Query: `code`, `state`, `session_state`, `error`.

## Admin settings

All of these require an admin session.

- `GET /api/settings/provisioning` lists the provisioning configurations.
- `POST /api/settings/provisioning` creates one. Params: `data`, an object with `provisioningDomain`, `emailTemplate`, `imapUser`, `imapHost`, `imapPort`, `imapSslMode`, `smtpUser`, `smtpHost`, `smtpPort`, `smtpSslMode`, `sieveEnabled`, `sieveUser`, `sieveHost`, `sievePort`, `sieveSslMode`, `masterPasswordEnabled`, `masterUser`, `masterPassword`, `ldapAliasesProvisioning`, `ldapAliasesAttribute`.
- `POST /api/settings/provisioning/{id}` updates one. Params: `data`, same shape.
- `DELETE /api/settings/provisioning/{id}` removes a configuration and deprovisions the accounts it created.
- `PUT /api/settings/provisioning/all` runs provisioning for all users now.
- `POST /api/settings/antispam` sets the spam reporting addresses. Params: `spam`, `ham`.
- `DELETE /api/settings/antispam` clears them.
- `POST /api/settings/allownewaccounts` controls whether users may add their own accounts. Params: `allowed`.
- `PUT /api/settings/llm` turns LLM processing on or off. Params: `enabled`.
- `PUT /api/settings/importance-classification-default` sets the default for new users. Params: `enabledByDefault`.
- `PUT /api/settings/layout-message-view` sets the default message list layout. Params: `value` (`threaded` or `singleton`).

## Endpoints declared but not implemented

`aliases#show`, `mailboxes#show` and `mailboxes#update` exist as resource routes but their controller methods throw `NotImplemented`.
