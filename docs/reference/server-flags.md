<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Server flags

*How the client learns each appendix flag of the parity matrix (nextcloud/mail#13797)
without the web page's initial state. Written by WS-16; every source below was read in the
live server's code (Mail 5.12.0-rc.1, Nextcloud 36) and probed against
`http://nextcloud.local` on 2026-10-03.*

The web client gets all of these from `initial-state-mail-*` attributes that
`lib/Controller/PageController.php::index` renders into the HTML page. A native client does
not load that page ([ADR-0078](../decisions/0078-flags-come-from-apis-or-default-on.md)),
so each flag needs an API source, or it falls back to the **contingency**:

> A flag with no API source is treated as **feature on**. When the server then refuses, its
> own error message is surfaced in the UI unchanged, and the gap is written up in
> [../feedback/server-findings.md](../feedback/server-findings.md).

Every flag is **instance-wide server configuration**, never an account field: the values
live in app config, system config, or the set of installed apps. They are stored once per
login, in the nullable flag columns on `login` ([ADR-0079](../decisions/0079-a-login-table-roots-instance-state.md));
NULL means "not discovered yet" and reads as the contingency.

None of the sources below needs admin rights. The provisioning API
(`GET /ocs/v2.php/apps/provisioning_api/api/v1/config/apps/{app}/{key}`) does expose
`core/backgroundjobs_mode`, `mail/allow_new_mail_accounts` and `mail/llm_processing`, but
only to admins (`alice` gets 403) — a client that behaved differently for admins would be
wrong for everyone else, so it is not used.

## Summary

| Flag | Server source | Client source | Contingency used? |
| --- | --- | --- | --- |
| `allow-new-accounts` | app config `mail.allow_new_mail_accounts` (default true) | none | **Yes** |
| `disable-scheduled-send` | `core.backgroundjobs_mode == "ajax"` | none | **Yes** |
| `disable-snooze` | `core.backgroundjobs_mode == "ajax"` | none | **Yes** |
| `llm_summaries_available` | `mail.llm_processing` ∧ task type `core:text2text:summary` | TaskProcessing task types, then the route's 204 | Partly |
| `llm_translation_enabled` | `mail.llm_processing` ∧ task type `core:text2text:translate` | `translation/languages`, then TaskProcessing | Partly |
| `llm_freeprompt_available` | `mail.llm_processing` ∧ task type `core:text2text` | TaskProcessing task types, then the route's 204 | Partly |
| `llm_followup_available` | `mail.llm_processing` ∧ task type `core:text2text` | TaskProcessing task types | Partly |
| `context_chat_available` | `context_chat` app enabled for the user | TaskProcessing task types | No |
| `importance_classification_default` | app config `mail.importance_classification_default` | none | **Yes** |
| `enable-system-out-of-office` | `AvailabilityCoordinator::isEnabled()` | capabilities `dav.absence-supported` | No |
| `attachment-size-limit` | system config `app.mail.attachment-size-limit` (0 = none) | none | **Yes** |
| `google-oauth-url` | app config `mail.google_oauth_client_id` | none | **Yes** (value flag) |
| `microsoft-oauth-url` | app config `mail.microsoft_oauth_client_id` + `…_tenant_id` | none | **Yes** (value flag) |

"Partly": the admin's `llm_processing` switch has no user-readable source, so the provider
check is a precondition and the route itself is the final word.

## Each flag

### `allow-new-accounts`

- **Server:** `PageController.php` → `appConfig->getValueBool('mail', 'allow_new_mail_accounts', true)`.
  Enforced in `AccountsController::create`: when false it answers
  `MailJsonResponse::error('Could not create account')`.
- **API source:** none. Capabilities carry no `mail` section; `GET /api/preferences/{key}`
  reads *user* preferences and answers `{"value":null}` for every flag name (probed).
- **Contingency:** the "Add account" action is always offered. A refusal arrives as the
  error envelope, whose message is shown as is — and it is generic ("Could not create
  account"), which is a finding: the user cannot tell "your admin disabled this" from a
  server fault.

### `disable-scheduled-send` and `disable-snooze`

- **Server:** both are `config->getAppValue('core', 'backgroundjobs_mode', 'ajax') === 'ajax'`.
  The live server runs `cron`, so both are false there.
- **API source:** none for a non-admin. Neither `POST /api/outbox` with `sendAt` nor
  `POST /api/messages/{id}/snooze` checks the mode — they succeed and the background job
  that delivers or wakes the message simply runs late (only when someone loads a page).
- **Contingency:** both features are on. There is no server error to surface: on an
  `ajax`-cron instance a scheduled message is sent, and a snoozed one wakes, late. The
  local mirror's own snooze table (`snooze.until`, schema v2) knows the wake time
  regardless, so the list can show the message on time even when the server is late.

### `llm_summaries_available`, `llm_freeprompt_available`, `llm_followup_available`

- **Server:** `mail.llm_processing` (admin switch, default false) **and** the task type is
  available: `core:text2text:summary` for summaries, `core:text2text` for free prompt and
  follow-up classification (`AiIntegrationsService::isLlmAvailable`).
- **API source:** `GET /ocs/v2.php/taskprocessing/tasktypes` (user OCS) lists available task
  types under `data.types`; the live server answers `{"types": []}`. A missing type means
  **off** with certainty.
- **Then:** with the type present, the admin switch is still unknown, so the feature is
  shown and the route decides. `GET /api/thread/{id}/summary` and
  `GET /api/messages/{id}/smartreply` answer **204, empty body** when processing is
  unavailable (observed live); `MailClient` decodes that to a nil payload, the fetcher
  writes an `empty` `serverResult` row, and the UI hides the result area for that message.
  An `empty` row is re-asked after at most fifteen minutes
  (`ServerResultKind.emptyRetryAfter`), so the admin turning processing on reaches a reader
  the next time a message is opened, without a relaunch.

### `llm_translation_enabled`

- **Server:** `mail.llm_processing` ∧ task type `core:text2text:translate`.
- **API source:** `GET /ocs/v2.php/translation/languages` — `data.languages` is empty when
  no translation provider exists (live: `{"languages":[],"languageDetection":false}`); the
  TaskProcessing list is the cross-check. `POST /ocs/v2.php/translation/translate` without a
  provider is OCS **412** "No translation provider available" (live).
- **Contingency for the admin switch:** as for the other `llm_*` flags.

### `context_chat_available`

- **Server:** `appManager->isEnabledForUser('context_chat')`.
- **API source:** the `context_chat` app registers the `context_chat:context_chat` task
  type, so `GET /ocs/v2.php/taskprocessing/tasktypes` answers this without guessing. Not
  installed on the live server (empty list).

### `importance_classification_default`

- **Server:** `ClassificationSettingsService::isClassificationEnabledByDefault()`, app
  config. The web form pre-ticks "classify importance" from it and **sends the value
  explicitly** on create.
- **API source:** none. And omitting it does not get the admin's default:
  `AccountsController::create` passes `null` through `SetupService::createNewAccount`, and
  `MailAccount` then keeps its property default `classificationEnabled = true`
  (`lib/Db/MailAccount.php`), whatever the admin chose.
- **Contingency:** the setup form shows the toggle on (feature on) and sends what the user
  leaves. After creation the per-account truth is the account payload's
  `classificationEnabled`, which `PATCH /api/accounts/{id}` changes.

### `enable-system-out-of-office`

- **Server:** `OC\User\AvailabilityCoordinator::isEnabled()` — core config
  `hide_absence_settings` is `no`.
- **API source:** the same call gates `dav` capabilities: `absence-supported` and
  `absence-replacement` are present only when it is true
  (`apps/dav/lib/Capabilities.php`). `GET /ocs/v2.php/cloud/capabilities` → `dav` on the
  live server: `"absence-supported": true`. Per account, `outOfOfficeFollowsSystem` in the
  account payload says whether that account follows it.

### `attachment-size-limit`

- **Server:** system config `app.mail.attachment-size-limit`, bytes, 0 for none (live: 0).
- **API source:** none — and the server does not enforce it: only `src/components/Composer.vue`
  reads it. `POST /api/attachments` takes whatever it is sent.
- **Contingency:** no client-side cap (feature on). An oversized message is refused, if at
  all, by the SMTP server at send time; that refusal is the server's error the user sees
  (the send path's failure surface is WS-23's).

### `google-oauth-url` and `microsoft-oauth-url`

- **Server:** built in `PageController` from `google_oauth_client_id` (and
  `microsoft_oauth_client_id` + `microsoft_oauth_tenant_id`) with the redirect URI
  `mail.googleIntegration.oauthRedirect` / `mail.microsoftIntegration.oauthRedirect` and a
  `state` placeholder the frontend fills from `POST /api/oauth/state`. Only rendered when
  configured; absent on the live server.
- **API source:** none. These are values, not switches: "feature on" cannot invent a client
  id.
- **Contingency:** the setup window offers no provider sign-in button; a Google or
  Microsoft address goes through the normal password form, and the server's answer (an
  IMAP authentication failure, shown verbatim) is what the user gets. The OAuth plumbing
  — `POST /api/oauth/state` → `JSONEnvelope<OAuthState>` — is built and tested so that a
  server which exposes the URL needs no client protocol work.

## Refresh

The three discovery reads are cheap — capabilities, `taskprocessing/tasktypes`,
`translation/languages` — and every one is a retryable GET. Whoever mirrors server state
refreshes them together and stamps `login.flagsFetchedAt`; no workstream brief names that
owner yet (reported by WS-16). Until one does, nothing writes the `llm_*` and
`context_chat_available` columns: they stay NULL, every gate reads "on", and the route's
own answer (the `empty` row above) is the only "off" a reader sees — which therefore can
never be stale beyond `emptyRetryAfter`.
